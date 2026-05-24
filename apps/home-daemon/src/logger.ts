type Level = 'debug' | 'info' | 'warn' | 'error';

const order: Record<Level, number> = { debug: 0, info: 1, warn: 2, error: 3 };

export function createLogger(min: Level) {
  const log = (level: Level, msg: string, meta?: Record<string, unknown>) => {
    if (order[level] < order[min]) return;
    const line = { ts: new Date().toISOString(), level, msg, ...meta };
    // eslint-disable-next-line no-console
    console[level === 'debug' ? 'log' : level](JSON.stringify(line));
  };
  return {
    debug: (msg: string, meta?: Record<string, unknown>) => log('debug', msg, meta),
    info: (msg: string, meta?: Record<string, unknown>) => log('info', msg, meta),
    warn: (msg: string, meta?: Record<string, unknown>) => log('warn', msg, meta),
    error: (msg: string, meta?: Record<string, unknown>) => log('error', msg, meta),
  };
}

export type Logger = ReturnType<typeof createLogger>;
