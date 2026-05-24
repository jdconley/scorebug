import type { HomeMessage, HomeReport } from '@scorebug/protocol';
import type { Logger } from './logger.js';

/**
 * Minimal WebSocket shape we depend on. Lets us swap between `ws`, the Node
 * WebSocket adapter, and a fake transport in tests.
 */
export interface HomeSocket {
  send(data: string): void;
  close(code?: number, reason?: string): void;
}

/**
 * Tracks (at most one) connected home daemon. The home is the source of truth for
 * pipeline state; the control plane mirrors what home reports.
 */
export class HomeBus {
  private socket: HomeSocket | undefined;
  private readonly onReportListeners = new Set<(r: HomeReport) => void>();

  constructor(private readonly log: Logger) {}

  attach(socket: HomeSocket): void {
    if (this.socket) {
      this.log.warn('home_socket_replaced');
      this.socket.close(4000, 'replaced');
    }
    this.socket = socket;
    this.log.info('home_socket_attached');
  }

  detach(socket: HomeSocket): void {
    if (this.socket === socket) {
      this.socket = undefined;
      this.log.info('home_socket_detached');
    }
  }

  isConnected(): boolean {
    return this.socket !== undefined;
  }

  /** Send a control→home message. Throws if no home is currently connected. */
  send(msg: HomeMessage): void {
    if (!this.socket) {
      throw new Error('home_not_connected');
    }
    this.socket.send(JSON.stringify(msg));
  }

  /** Called by the WS adapter when home sends a report. */
  ingestReport(raw: string): void {
    let parsed: HomeReport;
    try {
      parsed = JSON.parse(raw) as HomeReport;
    } catch {
      this.log.warn('home_report_invalid_json', { raw: raw.slice(0, 200) });
      return;
    }
    this.log.debug('home_report', { type: parsed.type, gameId: parsed.gameId });
    for (const listener of this.onReportListeners) listener(parsed);
  }

  onReport(listener: (r: HomeReport) => void): () => void {
    this.onReportListeners.add(listener);
    return () => this.onReportListeners.delete(listener);
  }
}
