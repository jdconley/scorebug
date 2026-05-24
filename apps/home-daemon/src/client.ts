import WebSocket from 'ws';
import type { HomeMessage, HomeReport } from '@scorebug/protocol';
import type { Logger } from './logger.js';

export type ClientHandlers = {
  onMessage: (msg: HomeMessage) => void;
  onClose?: () => void;
};

/**
 * Outbound WebSocket to the control plane with exponential-backoff reconnect.
 * The home is the source of truth for pipeline state; on reconnect we don't
 * try to resync anything — control plane will adopt whatever home reports.
 */
export class ControlPlaneClient {
  private socket: WebSocket | undefined;
  private closed = false;
  private reconnectMs = 1000;
  private readonly maxReconnectMs = 30_000;

  constructor(
    private readonly url: string,
    private readonly token: string,
    private readonly log: Logger,
    private readonly handlers: ClientHandlers,
  ) {}

  start(): void {
    this.connect();
  }

  stop(): void {
    this.closed = true;
    this.socket?.close(1000, 'shutdown');
  }

  report(report: HomeReport): void {
    if (this.socket?.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify(report));
    } else {
      this.log.warn('report_dropped_socket_not_open', { type: report.type });
    }
  }

  private connect(): void {
    if (this.closed) return;
    const url = `${this.url}?token=${encodeURIComponent(this.token)}`;
    this.log.info('ws_connecting', { url: this.url });
    const ws = new WebSocket(url);
    this.socket = ws;

    ws.once('open', () => {
      this.log.info('ws_open');
      this.reconnectMs = 1000;
    });

    ws.on('message', (data) => {
      const raw = typeof data === 'string' ? data : (data as Buffer).toString();
      let msg: HomeMessage;
      try {
        msg = JSON.parse(raw) as HomeMessage;
      } catch (err) {
        this.log.warn('ws_message_invalid_json', { err: String(err) });
        return;
      }
      try {
        this.handlers.onMessage(msg);
      } catch (err) {
        this.log.error('handler_threw', { err: String(err), type: msg.type });
      }
    });

    ws.once('close', (code, reason) => {
      this.log.warn('ws_closed', { code, reason: reason.toString() });
      this.handlers.onClose?.();
      if (!this.closed) this.scheduleReconnect();
    });

    ws.once('error', (err) => {
      this.log.warn('ws_error', { err: String(err) });
    });
  }

  private scheduleReconnect(): void {
    const ms = this.reconnectMs;
    this.reconnectMs = Math.min(this.maxReconnectMs, this.reconnectMs * 2);
    this.log.info('ws_reconnect_scheduled', { ms });
    setTimeout(() => this.connect(), ms);
  }
}
