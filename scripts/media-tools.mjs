import { accessSync, constants, existsSync } from 'node:fs';
import { delimiter, dirname, isAbsolute, join, resolve } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execute = promisify(execFile);
export function executable(name, env = process.env) {
  if (!name.trim()) return name;
  if (isAbsolute(name) || name.includes('/')) return resolve(name);
  return (
    (env.PATH ?? '')
      .split(delimiter)
      .map((dir) => join(dir, name))
      .find((path) => {
        try {
          accessSync(path, constants.X_OK);
          return true;
        } catch {
          return false;
        }
      }) ?? name
  );
}

export function mediaTools(env = process.env) {
  const full = [
    '/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg',
    '/usr/local/opt/ffmpeg-full/bin/ffmpeg',
  ];
  const ffmpeg = executable(
    env.FFMPEG_PATH ??
      (process.platform === 'darwin' ? (full.find(existsSync) ?? 'ffmpeg') : 'ffmpeg'),
    env,
  );
  const sibling = join(dirname(ffmpeg), 'ffprobe');
  const ffprobe = executable(
    env.FFPROBE_PATH ?? (isAbsolute(ffmpeg) && existsSync(sibling) ? sibling : 'ffprobe'),
    env,
  );
  const font =
    env.FONT_PATH ??
    (process.platform === 'darwin'
      ? '/System/Library/Fonts/Supplemental/Arial.ttf'
      : '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf');
  return { ffmpeg, ffprobe, font };
}

export async function command(binary, args, timeout = 15_000) {
  try {
    const result = await execute(binary, args, { timeout, maxBuffer: 4 * 1024 * 1024 });
    return { ok: true, ...result };
  } catch (error) {
    return {
      ok: false,
      stdout: error.stdout ?? '',
      stderr: error.stderr ?? '',
      error: error.killed ? `Timed out after ${timeout} ms` : String(error.code ?? error.message),
    };
  }
}
