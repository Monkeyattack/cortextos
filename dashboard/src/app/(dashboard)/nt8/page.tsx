import { redirect } from 'next/navigation';

// NT8 Remote Control has moved to dashboard.profithits.app/nt8-remote
export default function Nt8Page() {
  redirect('https://dashboard.profithits.app/nt8-remote');
}
