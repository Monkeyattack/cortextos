#!/usr/bin/env python3
"""
Task #16: Events Table Anomaly Monitoring
Queries orbfutures_dashboard directly (NOT cc.profithits.app)
Analyzes events for anomalies in the last hour
Alerts if >3 anomalies detected
"""

import psycopg2
from datetime import datetime, timedelta, timezone
import sys

def check_events_anomalies():
    """Query events table and detect anomalies"""
    
    try:
        conn = psycopg2.connect(
            host="127.0.0.1",
            database="orbfutures_dashboard",
            user="orbfutures",
            password="orbfutures"
        )
        cur = conn.cursor()
        
        # Get events from last hour
        one_hour_ago = datetime.now(timezone.utc) - timedelta(hours=1)
        now = datetime.now(timezone.utc)
        
        cur.execute("""
            SELECT 
                id, timestamp, event_type, detail, account_name, created_at
            FROM events
            WHERE timestamp >= %s AND timestamp <= %s
            ORDER BY timestamp DESC
        """, (one_hour_ago, now))
        
        events = cur.fetchall()
        conn.close()
        
        print(f"[Task #16] Events from {one_hour_ago.isoformat()} to {now.isoformat()}")
        print(f"Total events in last hour: {len(events)}")
        
        # Detect anomalies
        anomalies = []
        
        # Anomaly 1: Connection drops (CONN_DROPPED events)
        conn_drops = [e for e in events if 'CONN_DROP' in e[2].upper()]
        if len(conn_drops) > 3:
            anomalies.append(f"HIGH_CONN_DROP_RATE: {len(conn_drops)} connection drops")
        
        # Anomaly 2: Repeated errors for same account
        account_events = {}
        for event in events:
            if event[4]:  # account_name
                if 'ERROR' in event[2].upper() or 'FAIL' in event[2].upper():
                    if event[4] not in account_events:
                        account_events[event[4]] = 0
                    account_events[event[4]] += 1
        
        for account, count in account_events.items():
            if count > 2:  # Threshold: >2 errors for same account
                anomalies.append(f"ACCOUNT_ERROR_CLUSTER: {account} has {count} errors")
        
        # Anomaly 3: Unusual event type distribution
        event_types = {}
        for event in events:
            event_types[event[2]] = event_types.get(event[2], 0) + 1
        
        if len(events) > 10:
            for etype, count in event_types.items():
                if count / len(events) > 0.6:  # >60% of events
                    anomalies.append(f"SKEWED_EVENT_DISTRIBUTION: {etype} is {count/len(events)*100:.0f}% of events")
        
        # Anomaly 4: Specific anomalous event types
        anomalous_types = ['ERROR', 'FAILED', 'CRASHED', 'TIMEOUT', 'HALTED']
        for event in events:
            if any(atype in event[2].upper() for atype in anomalous_types):
                # Count these per type
                pass
        
        anomalous_events = [e for e in events if any(atype in e[2].upper() for atype in anomalous_types)]
        if len(anomalous_events) > 5:
            anomalies.append(f"ANOMALOUS_EVENTS: {len(anomalous_events)} error-type events detected")
        
        # Report results
        print(f"\nAnomalies detected: {len(anomalies)}")
        if anomalies:
            for i, anomaly in enumerate(anomalies, 1):
                print(f"  {i}. {anomaly}")
        
        # Alert if >3 anomalies
        if len(anomalies) > 3:
            print(f"\n⚠️ ALERT: {len(anomalies)} anomalies detected (threshold: >3)")
            return True
        else:
            print(f"\n✓ Status: OK ({len(anomalies)} anomalies, threshold: >3)")
            return False
        
    except Exception as e:
        print(f"✗ Error: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    alert_triggered = check_events_anomalies()
    sys.exit(0 if not alert_triggered else 1)

