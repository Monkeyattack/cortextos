/**
 * Telegram Bot API client using built-in fetch (Node.js 20+).
 * No external dependencies.
 */

import { existsSync, readFileSync } from 'fs';
import { basename } from 'path';

/**
 * Telegram message size limit in UTF-16 code units. Telegram counts in
 * code units, so we do too — this matches what the API rejects at.
 */
export const TELEGRAM_MAX_LEN = 4096;

/**
 * Split `text` into chunks no longer than `maxLen` characters, preferring
 * natural boundaries in this order:
 *
 *   1. Paragraph break (\n\n)
 *   2. Single newline (\n)
 *   3. Sentence end (. ! ? followed by whitespace)
 *   4. Word boundary (whitespace)
 *   5. Hard cut at maxLen
 *
 * Never splits inside an unbalanced Markdown v1 entity (*, _, backtick,
 * or a [ without its matching ]). If the best boundary lands on an
 * unbalanced split, it keeps walking back to the next candidate. Only
 * when every candidate is unbalanced does it fall back to a hard cut at
 * maxLen — the old behavior, preserved for pathological inputs.
 */
export function splitForTelegram(text: string, maxLen: number = TELEGRAM_MAX_LEN): string[] {
  if (text.length <= maxLen) return [text];

  const chunks: string[] = [];
  let i = 0;
  while (i < text.length) {
    const remaining = text.length - i;
    if (remaining <= maxLen) {
      chunks.push(text.slice(i));
      break;
    }

    const windowEnd = i + maxLen;
    // Back half of the window — keeps chunks from collapsing to tiny fragments.
    const minSplit = i + Math.floor(maxLen / 2);

    const candidates: number[] = [];

    // Paragraph break — split lands AFTER the "\n\n" so both newlines
    // stay with the prior chunk.
    const paraIdx = text.lastIndexOf('\n\n', windowEnd - 1);
    if (paraIdx >= minSplit && paraIdx + 2 <= windowEnd) candidates.push(paraIdx + 2);

    // Single newline.
    const nlIdx = text.lastIndexOf('\n', windowEnd - 1);
    if (nlIdx >= minSplit) candidates.push(nlIdx + 1);

    // Sentence end — scan the window for "[.!?] " and take the last match.
    let sentSplit = -1;
    for (let j = windowEnd - 2; j >= minSplit; j--) {
      const c = text.charCodeAt(j);
      const n = text.charCodeAt(j + 1);
      if ((c === 46 || c === 33 || c === 63) && (n === 32 || n === 9 || n === 10)) {
        sentSplit = j + 2;
        break;
      }
    }
    if (sentSplit >= minSplit) candidates.push(sentSplit);

    // Word boundary — last whitespace in the window.
    let wsSplit = -1;
    for (let j = windowEnd - 1; j >= minSplit; j--) {
      const c = text.charCodeAt(j);
      if (c === 32 || c === 9 || c === 10) { wsSplit = j + 1; break; }
    }
    if (wsSplit >= minSplit) candidates.push(wsSplit);

    // Pick the best candidate (earliest in the preference order) whose
    // resulting chunk has balanced markdown entities.
    let splitAt = -1;
    for (const c of candidates) {
      if (isMarkdownBalanced(text.slice(i, c))) { splitAt = c; break; }
    }

    // Fallback: no natural-boundary candidate was balanced. Scan the
    // window with a running delimiter tally and remember the latest
    // position inside [minSplit, windowEnd] at which all entities are
    // balanced. One O(maxLen) pass — cheap compared to the network
    // round-trip. If no balanced position exists (pathological input
    // whose entity spans more than maxLen), fall through to a hard cut
    // at windowEnd — no worse than the pre-patch behavior.
    if (splitAt < 0) {
      let asterisk = 0, underscore = 0, backtick = 0, bracket = 0;
      let bestBalanced = -1;
      for (let j = i; j < windowEnd; j++) {
        const c = text.charCodeAt(j);
        if (c === 42) asterisk++;
        else if (c === 95) underscore++;
        else if (c === 96) backtick++;
        else if (c === 91) bracket++;
        else if (c === 93 && bracket > 0) bracket--;
        if (
          j + 1 >= minSplit &&
          asterisk % 2 === 0 &&
          underscore % 2 === 0 &&
          backtick % 2 === 0 &&
          bracket === 0
        ) {
          bestBalanced = j + 1;
        }
      }
      splitAt = bestBalanced >= 0 ? bestBalanced : windowEnd;
    }

    chunks.push(text.slice(i, splitAt));
    i = splitAt;
  }
  return chunks;
}

/**
 * Returns true iff every `*`, `_`, backtick, and `[` in `text` has a
 * closing match. Used by splitForTelegram to reject candidate split
 * points that would leave half a bold/italic/code span dangling in one
 * chunk. Conservative — a backslash-escaped delimiter is still counted
 * here; sanitizeMarkdown strips most of those before we see the text,
 * so this is safe in practice. Cost of being conservative: a few inputs
 * fall through to the hard-cut fallback.
 */
function isMarkdownBalanced(text: string): boolean {
  let asterisk = 0, underscore = 0, backtick = 0, bracket = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c === 42) asterisk++;              // *
    else if (c === 95) underscore++;       // _
    else if (c === 96) backtick++;         // `
    else if (c === 91) bracket++;          // [
    else if (c === 93 && bracket > 0) bracket--; // ]
  }
  return asterisk % 2 === 0 && underscore % 2 === 0 && backtick % 2 === 0 && bracket === 0;
}

export class TelegramAPI {
  private baseUrl: string;
  private lastSendTime: Map<string, number> = new Map();
  // Chat IDs already warned for the self_chat trap. Keeps the runtime
  // diagnostic emitted at most once per chat_id per process lifetime.
  private warnedSelfChat: Set<string> = new Set();

  constructor(token: string) {
    this.baseUrl = `https://api.telegram.org/bot${token}`;
  }

  /**
   * Convert a Markdown-flavored string to Telegram HTML.
   *
   * Why HTML instead of Markdown v1: Telegram Markdown v1 silently drops
   * content when it encounters an unclosed or unrecognised entity (backtick
   * spans containing `--flags`, `$` before numbers, `_` inside filenames,
   * etc.). HTML parse mode rejects the whole message with an explicit error
   * instead — no silent data loss.
   *
   * Processing order (matters — do not reorder):
   *   1. HTML-escape & < > in raw text (& first, then < >). Backticks, *,
   *      _ are not HTML-special so they survive intact for step 2+.
   *   2. Fenced code blocks (``` ... ```) → <pre><code>...</code></pre>
   *   3. Inline code (`...`) → <code>...</code>
   *   4. Bold (*...*) → <b>...</b>
   *   5. Italic (_..._) — word-boundary aware to avoid snake_case false positives
   *   6. Links ([text](url)) → <a href="url">text</a>
   *
   * Pass `plainText: true` to skip conversion (just HTML-escape and send raw).
   */
  private markdownToHtml(text: string, plainText = false): string {
    // Step 1: HTML-escape (& must be first to avoid double-escaping)
    let html = text
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');

    if (plainText) return html;

    // Step 2: Fenced code blocks — multiline, processed before inline `
    html = html.replace(/```(?:\w*\n?)?([\s\S]*?)```/g, (_, code) =>
      `<pre><code>${code.trimEnd()}</code></pre>`,
    );

    // Step 3: Inline code — single backtick, no newlines inside
    html = html.replace(/`([^`\n]+)`/g, '<code>$1</code>');

    // Step 4: Bold — *text* (no newlines, greedy-avoided)
    html = html.replace(/\*([^*\n]+)\*/g, '<b>$1</b>');

    // Step 5: Italic — _text_ with word-boundary guard (no newlines)
    html = html.replace(/(?<![_\w])_([^_\n]+)_(?![_\w])/g, '<i>$1</i>');

    // Step 6: Links — [text](url). URL may contain HTML-escaped & (&amp;) which is fine.
    html = html.replace(/\[([^\]]+)\]\((https?:\/\/[^)]+)\)/g, '<a href="$2">$1</a>');

    return html;
  }

  /**
   * Split HTML text into chunks at paragraph/newline boundaries to avoid
   * breaking mid-entity. Falls back to hard split only if a single line
   * exceeds maxLen.
   */
  private splitHtml(text: string, maxLen: number): string[] {
    if (text.length <= maxLen) return [text];

    const chunks: string[] = [];
    let remaining = text;
    while (remaining.length > maxLen) {
      const window = remaining.slice(0, maxLen);
      // Prefer splitting at a paragraph break (\n\n), then a newline
      let splitAt = window.lastIndexOf('\n\n');
      if (splitAt > 0) {
        splitAt += 2; // include the double-newline in the preceding chunk
      } else {
        splitAt = window.lastIndexOf('\n');
        if (splitAt > 0) splitAt += 1;
        else splitAt = maxLen; // no newline — hard split as last resort
      }
      chunks.push(remaining.slice(0, splitAt));
      remaining = remaining.slice(splitAt);
    }
    if (remaining.length > 0) chunks.push(remaining);
    return chunks;
  }

  /**
   * Send a text message. Converts Markdown to HTML and sends with
   * `parse_mode: "HTML"`. HTML mode never silently drops content — bad
   * markup produces an explicit API error rather than invisible text.
   *
   * Pass `{ parseMode: null }` to send plain text (no formatting, no
   * conversion). Useful for raw log output or user-supplied text that
   * should not be interpreted as Markdown.
   *
   * Long messages are split at paragraph/newline boundaries (not raw char
   * offsets) so formatting entities are never cut mid-span.
   */
  async sendMessage(
    chatId: string | number,
    text: string,
    replyMarkup?: object,
    opts?: {
      parseMode?: 'HTML' | null;
      onParseFallback?: (reason: string) => void;
    },
  ): Promise<any> {
    const plainText = opts?.parseMode === null;
    const html = this.markdownToHtml(text, plainText);

    await this.rateLimit(String(chatId));

    const chunks = this.splitHtml(html, 4096);

    let lastResult: any;
    for (let i = 0; i < chunks.length; i++) {
      const chunk = chunks[i];
      const isLastChunk = i === chunks.length - 1;
      lastResult = await this.sendChunk(
        chatId,
        chunk,
        plainText ? null : 'HTML',
        isLastChunk ? replyMarkup : undefined,
      );
    }
    return lastResult;
  }

  /**
   * Send a single chunk with the given parse mode.
   */
  private async sendChunk(
    chatId: string | number,
    text: string,
    parseMode: 'HTML' | null,
    replyMarkup: object | undefined,
  ): Promise<any> {
    const basePayload: Record<string, unknown> = {
      chat_id: chatId,
      text,
      ...(replyMarkup ? { reply_markup: replyMarkup } : {}),
    };

    const payload =
      parseMode === null ? basePayload : { ...basePayload, parse_mode: parseMode };

    try {
      return await this.post('sendMessage', payload);
    } catch (err) {
      // self_chat safety net: a 403 "bots can't send messages to bots" at
      // sendMessage time means CHAT_ID likely equals the bot's own user id.
      const msg = err instanceof Error ? err.message : String(err);
      if (/bots can'?t send messages to bots/i.test(msg)) {
        const key = String(chatId);
        if (!this.warnedSelfChat.has(key)) {
          this.warnedSelfChat.add(key);
          console.warn(
            `[telegram] self_chat trap likely: chat_id=${key} resolved to another bot. ` +
            `Check .env — CHAT_ID must be YOUR Telegram user id, not the BOT_TOKEN prefix. ` +
            `Fix by sending /start to the bot from your own account and reading the chat id via getUpdates.`,
          );
        }
      }
      throw err;
    }
  }

  /**
   * Send a photo with optional caption and reply markup.
   * Uses multipart/form-data via built-in Node.js APIs.
   */
  async sendPhoto(
    chatId: string | number,
    imagePath: string,
    caption?: string,
    replyMarkup?: object,
  ): Promise<any> {
    if (!existsSync(imagePath)) {
      throw new Error(`Image file not found: ${imagePath}`);
    }

    await this.rateLimit(String(chatId));

    const fileData = readFileSync(imagePath);
    const fileName = basename(imagePath);

    // Build multipart form data using built-in FormData + Blob
    const formData = new FormData();
    formData.append('chat_id', String(chatId));
    formData.append('photo', new Blob([fileData]), fileName);
    if (caption) {
      formData.append('caption', caption);
    }
    if (replyMarkup) {
      formData.append('reply_markup', JSON.stringify(replyMarkup));
    }

    try {
      const response = await fetch(`${this.baseUrl}/sendPhoto`, {
        method: 'POST',
        body: formData,
        signal: AbortSignal.timeout(60000),
      });
      const result = await response.json() as any;
      if (!result.ok) {
        throw new Error(`Telegram API error: ${result.description || 'Unknown error'}`);
      }
      return result;
    } catch (err) {
      if (err instanceof Error && err.message.startsWith('Telegram API error')) {
        throw err;
      }
      if (err instanceof Error && (err.name === 'TimeoutError' || err.name === 'AbortError')) {
        throw new Error(`Telegram API request timed out after 60s: sendPhoto`);
      }
      throw new Error(`Telegram API request failed: ${err}`);
    }
  }

  /**
   * Send a document (file) with optional caption. Works for any file type
   * that isn't a photo: PDFs, text files, archives, etc.
   */
  async sendDocument(
    chatId: string | number,
    filePath: string,
    caption?: string,
    replyMarkup?: object,
  ): Promise<any> {
    if (!existsSync(filePath)) {
      throw new Error(`File not found: ${filePath}`);
    }

    await this.rateLimit(String(chatId));

    const fileData = readFileSync(filePath);
    const fileName = basename(filePath);

    const formData = new FormData();
    formData.append('chat_id', String(chatId));
    formData.append('document', new Blob([fileData]), fileName);
    if (caption) {
      formData.append('caption', caption);
    }
    if (replyMarkup) {
      formData.append('reply_markup', JSON.stringify(replyMarkup));
    }

    try {
      const response = await fetch(`${this.baseUrl}/sendDocument`, {
        method: 'POST',
        body: formData,
        signal: AbortSignal.timeout(60000),
      });
      const result = await response.json() as any;
      if (!result.ok) {
        throw new Error(`Telegram API error: ${result.description || 'Unknown error'}`);
      }
      return result;
    } catch (err) {
      if (err instanceof Error && err.message.startsWith('Telegram API error')) {
        throw err;
      }
      if (err instanceof Error && (err.name === 'TimeoutError' || err.name === 'AbortError')) {
        throw new Error(`Telegram API request timed out after 60s: sendDocument`);
      }
      throw new Error(`Telegram API request failed: ${err}`);
    }
  }

  /**
   * Get updates via long polling.
   */
  async getUpdates(offset: number, timeout: number = 1): Promise<any> {
    return this.post('getUpdates', {
      offset,
      timeout,
      allowed_updates: ['message', 'callback_query', 'message_reaction'],
    });
  }

  /**
   * Answer a callback query.
   */
  async answerCallbackQuery(callbackQueryId: string, text?: string): Promise<any> {
    return this.post('answerCallbackQuery', {
      callback_query_id: callbackQueryId,
      text: text || 'OK',
    });
  }

  /**
   * Edit a message's text.
   */
  async editMessageText(
    chatId: string | number,
    messageId: number,
    text: string,
    replyMarkup?: object,
  ): Promise<any> {
    return this.post('editMessageText', {
      chat_id: chatId,
      message_id: messageId,
      text,
      ...(replyMarkup ? { reply_markup: replyMarkup } : {}),
    });
  }

  /**
   * Send typing indicator.
   */
  async sendChatAction(chatId: string | number, action: string = 'typing'): Promise<any> {
    return this.post('sendChatAction', {
      chat_id: chatId,
      action,
    });
  }

  /**
   * Get file info for downloading.
   */
  async getFile(fileId: string): Promise<any> {
    return this.post('getFile', { file_id: fileId });
  }

  /**
   * Download a file from Telegram servers.
   */
  async downloadFile(filePath: string): Promise<Buffer> {
    const url = `https://api.telegram.org/file/bot${this.getToken()}/${filePath}`;
    const response = await fetch(url, { signal: AbortSignal.timeout(30000) });
    if (!response.ok) {
      throw new Error(`Failed to download file: ${response.status}`);
    }
    const arrayBuffer = await response.arrayBuffer();
    return Buffer.from(arrayBuffer);
  }

  /**
   * Register bot commands for autocomplete.
   */
  async setMyCommands(commands: Array<{ command: string; description: string }>): Promise<any> {
    return this.post('setMyCommands', { commands });
  }

  /**
   * Make a POST request to the Telegram API.
   */
  private async post(method: string, data: object): Promise<any> {
    try {
      const response = await fetch(`${this.baseUrl}/${method}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data),
        signal: AbortSignal.timeout(15000),
      });
      const result = await response.json() as any;
      if (!result.ok) {
        throw new Error(`Telegram API error: ${result.description || 'Unknown error'}`);
      }
      return result;
    } catch (err) {
      if (err instanceof Error && err.message.startsWith('Telegram API error')) {
        throw err;
      }
      // AbortSignal.timeout surfaces as DOMException name=TimeoutError (or AbortError).
      // Surface as a clean retryable error so the poller loop recovers next tick
      // instead of silently hanging on a wedged TCP connection.
      if (err instanceof Error && (err.name === 'TimeoutError' || err.name === 'AbortError')) {
        throw new Error(`Telegram API request timed out after 15s: ${method}`);
      }
      throw new Error(`Telegram API request failed: ${err}`);
    }
  }

  /**
   * Simple rate limiter: 1 message per second per chat.
   */
  private async rateLimit(chatId: string): Promise<void> {
    const now = Date.now();
    const last = this.lastSendTime.get(chatId) || 0;
    const elapsed = now - last;
    if (elapsed < 1000) {
      await new Promise(resolve => setTimeout(resolve, 1000 - elapsed));
    }
    this.lastSendTime.set(chatId, Date.now());
  }

  /**
   * Extract token from base URL.
   */
  private getToken(): string {
    return this.baseUrl.replace('https://api.telegram.org/bot', '');
  }
}
