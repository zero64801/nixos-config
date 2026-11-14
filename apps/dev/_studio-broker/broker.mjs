// Launches, lists and stops Roblox Studio, and records its sound, for a Lumen server confined in a PID namespace of
// its own. Studio runs in Vinegar's Flatpak, which the server can neither start nor see, so this runs in the user's
// session, outside every sandbox, and answers the protocol of Lumen's ROBLOX_STUDIO_LAUNCH_BROKER: one JSON request
// line per connection, one JSON reply, except for audio, which answers with a header line and then streams samples.
// systemd holds the socket and starts this on the first connection. It leaves once idle, which loses nothing: Studio
// runs in a scope of its own, and the next connection starts this again.
// Whatever reaches the socket may ask, so every request is checked here. The state folder must be one no sandbox can
// write: this process writes and deletes there unsandboxed. The first places folder is the one sandboxes write, and
// is only ever read here. Any further places folders must be ones no sandbox can write, since a stopped Studio's lock
// file is deleted there.
// Usage: node broker.mjs <idle seconds> <state dir> <sandbox places dir> [<places dir>...]
import { execFile, spawn } from 'node:child_process';
import {
  closeSync,
  linkSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { createServer } from 'node:net';
import { isAbsolute, join, relative, resolve } from 'node:path';
import { promisify } from 'node:util';

const [idleSeconds, stateDir, ...placesDirs] = process.argv.slice(2);
const idleMs = Number(idleSeconds) * 1000;
if (!(idleMs > 0) || !stateDir || placesDirs.length === 0 || process.env.LISTEN_FDS !== '1') {
  console.error('usage: broker.mjs <idle seconds> <state dir> <sandbox places dir> [<places dir>...], started by its systemd socket');
  process.exit(2);
}
const lockFolders = placesDirs.slice(1);

const BUSCTL = '/run/current-system/sw/bin/busctl';
const SYSTEMD_RUN = '/run/current-system/sw/bin/systemd-run';
const FLATPAK = '/run/current-system/sw/bin/flatpak';
const PW_DUMP = '/run/current-system/sw/bin/pw-dump';
const PW_RECORD = '/run/current-system/sw/bin/pw-record';
const VINEGAR = ['run', '--branch=stable', '--arch=x86_64', '--command=vinegar', 'org.vinegarhq.Vinegar', 'run'];
const STUDIO_EXE = 'robloxstudiobeta.exe';
// Vinegar may install a Studio update first. Lumen waits 150 s for the reply.
const LAUNCH_TIMEOUT_MS = 120000;
const STOP_GRACE_MS = 4000;
const POLL_MS = 100;
const MAX_REQUEST_BYTES = 64 * 1024;
const LAUNCH_LOGS_KEPT = 10;
const LOG_TAIL_BYTES = 2048;
// A place path below the places folder. Plain names keep Wine's command line quoting out of play.
const SAFE_PLACE = /^[\w .()-]+(?:\/[\w .()-]+)*\.rbxlx?$/iu;
// Studio's own arguments for each task, in the order Lumen builds them.
const TASKS = {
  EditFile: ['--localPlaceFile'],
  EditPlace: ['--placeId', '--universeId'],
  EditPlaceRevision: ['--placeId', '--universeId', '--placeVersion'],
};
const FILETIME_UNIX_EPOCH = 116444736000000000n;
const FILETIME_TICKS_PER_SECOND = 10000000n;
const USER_HZ = 100n;
// A recording ends on its own after this, so a server that vanished without closing its socket leaves nothing running.
const AUDIO_MAX_MS = 120000;
const AUDIO_START_MS = 5000;
const AUDIO_SESSIONS = 8;

const uid = process.getuid();
const execFileAsync = promisify(execFile);
const launchLogDir = join(stateDir, 'launches');
let launches = 0;
let launchQueue = Promise.resolve();
let audioSessions = 0;

function log(message) {
  console.error(`${new Date().toISOString()} ${message}`);
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isGone(error) {
  return error?.code === 'ENOENT' || error?.code === 'ESRCH';
}

// btime is the wall clock minus uptime, so it moves when the clock is stepped. Lumen keeps start times in its
// registry and compares them exactly, so every broker in a boot converts with the first btime any of them read.
let bootTime;
function bootTimeSeconds() {
  if (bootTime !== undefined) return bootTime;
  const live = BigInt(/^btime\s+(\d+)$/mu.exec(readFileSync('/proc/stat', 'utf8'))[1]);
  const bootId = readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim();
  const anchor = join(stateDir, `boot-time-${bootId}`);
  try {
    bootTime = BigInt(readFileSync(anchor, 'utf8').trim());
    return bootTime;
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  const tmp = `${anchor}.${process.pid}.tmp`;
  writeFileSync(tmp, `${live}\n`);
  try {
    linkSync(tmp, anchor);
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
  } finally {
    unlinkSync(tmp);
  }
  for (const name of readdirSync(stateDir)) {
    if (name.startsWith('boot-time-') && !name.startsWith(`boot-time-${bootId}`)) rmSync(join(stateDir, name), { force: true });
  }
  bootTime = BigInt(readFileSync(anchor, 'utf8').trim());
  return bootTime;
}

// Field 3 of stat is the state and field 22 the start time, counted after the last ')' since comm may hold either.
function startedAt(pid) {
  const stat = readFileSync(`/proc/${pid}/stat`, 'utf8');
  const fields = stat.slice(stat.lastIndexOf(')') + 1).trim().split(/\s+/u);
  if (fields[0] === 'Z' || fields[0] === 'X') return undefined;
  const ticks = BigInt(fields[19]);
  return (FILETIME_UNIX_EPOCH + bootTimeSeconds() * FILETIME_TICKS_PER_SECOND + ticks * (FILETIME_TICKS_PER_SECOND / USER_HZ)).toString();
}

// The real UID from status, since /proc/<pid> itself is owned by root for processes that are not dumpable.
function realUid(pid) {
  return Number(/^Uid:\s+(\d+)/mu.exec(readFileSync(`/proc/${pid}/status`, 'utf8'))[1]);
}

function readStudio(pid) {
  try {
    if (realUid(pid) !== uid) return undefined;
    const argv = readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0');
    // Wine pads the rewritten command line with empty arguments.
    while (argv.length > 0 && argv[argv.length - 1] === '') argv.pop();
    if (argv[0]?.split(/[\\/]/u).pop().toLowerCase() !== STUDIO_EXE) return undefined;
    const started = startedAt(pid);
    if (started === undefined) return undefined;
    return { pid, startedAt: started, path: argv[0], commandLine: argv.join(' '), argv };
  } catch (error) {
    if (isGone(error) || error.code === 'EACCES') return undefined;
    throw error;
  }
}

function studioProcesses() {
  const found = [];
  for (const entry of readdirSync('/proc')) {
    if (!/^\d+$/u.test(entry)) continue;
    const studio = readStudio(Number(entry));
    if (studio) found.push(studio);
  }
  return found;
}

function publicProcess({ pid, startedAt: started, path, commandLine }) {
  return { pid, startedAt: started, path, commandLine };
}

function placeFile(file) {
  if (typeof file !== 'string' || !isAbsolute(file)) {
    throw new Error('--localPlaceFile must be an absolute path.');
  }
  // Vinegar's Flatpak reaches only its own data folder, where the places folders live.
  const root = placesDirs.find((dir) => !relative(dir, resolve(file)).startsWith('..'));
  const below = root === undefined ? '' : relative(root, resolve(file));
  if (!SAFE_PLACE.test(below)) {
    throw new Error(
      `Vinegar's Studio opens only .rbxl and .rbxlx files inside ${placesDirs.join(' or ')}, named with letters, ` +
      `digits, spaces and . _ ( ) -. Copy ${JSON.stringify(file)} there and launch the copy.`,
    );
  }
  let real;
  try {
    real = realpathSync(file);
  } catch {
    throw new Error(`Place file not found: ${JSON.stringify(file)}`);
  }
  // A sandbox may write a places folder, and a symlink there could aim Studio at anything the Flatpak reaches.
  if (real !== join(realpathSync(root), below)) {
    throw new Error(`Place paths must not go through symlinks: ${JSON.stringify(file)}`);
  }
  if (!statSync(real).isFile()) throw new Error(`Not a file: ${JSON.stringify(file)}`);
  // Studio names the place after the path it is given, which Lumen matches against the file it asked for.
  return `Z:${join(root, below).replaceAll('/', '\\')}`;
}

function studioArgs(args) {
  if (!Array.isArray(args) || args.some((arg) => typeof arg !== 'string')) {
    throw new Error('args must be an array of strings.');
  }
  const flags = args[0] === '--task' && Object.hasOwn(TASKS, args[1]) ? TASKS[args[1]] : undefined;
  if (!flags || args.length !== 2 + flags.length * 2) {
    throw new Error('Only --task EditFile, EditPlace and EditPlaceRevision launches with their own arguments are allowed.');
  }
  const out = ['--task', args[1]];
  flags.forEach((flag, index) => {
    const value = args[3 + index * 2];
    if (args[2 + index * 2] !== flag) throw new Error(`Expected ${flag} for --task ${args[1]}.`);
    if (flag === '--localPlaceFile') out.push(flag, placeFile(value));
    else if (/^[1-9]\d{0,18}$/u.test(value)) out.push(flag, value);
    else throw new Error(`${flag} must be a positive integer.`);
  });
  return out;
}

// The user manager's environment is the desktop session's, so Vinegar starts as it would from the app menu
// rather than with this process's environment, whose home may not be the user's.
async function sessionEnvironment() {
  const { stdout } = await execFileAsync(BUSCTL, [
    '--user', '--json=short', 'get-property',
    'org.freedesktop.systemd1', '/org/freedesktop/systemd1', 'org.freedesktop.systemd1.Manager', 'Environment',
  ], { timeout: 5000 });
  const env = {};
  for (const entry of JSON.parse(stdout).data) {
    const split = entry.indexOf('=');
    if (split > 0) env[entry.slice(0, split)] = entry.slice(split + 1);
  }
  return env;
}

function openLaunchLog(unit) {
  mkdirSync(launchLogDir, { recursive: true, mode: 0o700 });
  const file = join(launchLogDir, `${new Date().toISOString().replace(/[:.]/gu, '-')}-${unit}.log`);
  const fd = openSync(file, 'a', 0o600);
  const logs = readdirSync(launchLogDir).filter((name) => name.endsWith('.log')).sort();
  for (const name of logs.slice(0, Math.max(0, logs.length - LAUNCH_LOGS_KEPT))) rmSync(join(launchLogDir, name), { force: true });
  return { file, fd };
}

function logTail(file) {
  try {
    const content = readFileSync(file, 'utf8');
    const tail = content.slice(-LOG_TAIL_BYTES).trim();
    return tail ? ` Launcher output (${file}):\n${tail}` : ` The launcher wrote nothing (${file}).`;
  } catch {
    return '';
  }
}

// Wine shows Studio's arguments after argv[0], so the launch is the new Studio carrying exactly these.
function hasArgs(studio, args) {
  let at = 1;
  for (const arg of args) {
    at = studio.argv.indexOf(arg, at);
    if (at < 0) return false;
    at += 1;
  }
  return true;
}

async function launch(args) {
  const studio = studioArgs(args);
  const before = new Set(studioProcesses().map((proc) => proc.pid));
  launches += 1;
  // The time keeps the name free of a Studio that an earlier run of this broker left running.
  const unit = `lumen-studio-${Date.now().toString(36)}-${launches}`;
  const env = await sessionEnvironment();
  const launchLog = openLaunchLog(unit);
  let exit;
  try {
    // Its own scope keeps Studio alive when the editor whose session started this server closes. A Vinegar that
    // already runs takes the arguments over D-Bus and starts Studio itself, and this one exits at once.
    const child = spawn(SYSTEMD_RUN, [
      '--user', '--scope', '--collect', '--quiet', '--slice=app.slice', `--unit=${unit}`,
      '--description=Roblox Studio launched for Lumen', '--', FLATPAK, ...VINEGAR, ...studio,
    ], { env, cwd: env.HOME ?? '/', detached: true, stdio: ['ignore', launchLog.fd, launchLog.fd] });
    child.once('exit', (code, signal) => { exit = signal ? `signal ${signal}` : `code ${code}`; });
    child.once('error', (error) => { exit = error.message; });
    child.unref();
  } finally {
    closeSync(launchLog.fd);
  }
  log(`launch ${unit}: ${studio.join(' ')}`);

  const deadline = Date.now() + LAUNCH_TIMEOUT_MS;
  while (Date.now() < deadline) {
    await delay(POLL_MS);
    const fresh = studioProcesses().filter((proc) => !before.has(proc.pid));
    const exact = fresh.filter((proc) => hasArgs(proc, studio));
    const found = exact.length === 1 ? exact[0] : exact.length === 0 && fresh.length === 1 ? fresh[0] : undefined;
    if (found) {
      log(`launch ${unit}: Studio pid ${found.pid}`);
      return { process: publicProcess(found) };
    }
    if (exact.length > 1) throw new Error(`${exact.length} new Studio processes carry the same arguments; refusing to guess.`);
    if (exit !== undefined && exit !== 'code 0') {
      throw new Error(`Vinegar exited (${exit}) before Studio started.${logTail(launchLog.file)}`);
    }
  }
  throw new Error(
    `No new Studio process appeared within ${LAUNCH_TIMEOUT_MS / 1000} s. Vinegar ignores launches while it installs ` +
    `or updates Studio; its own logs are in ~/.var/app/org.vinegarhq.Vinegar/cache/vinegar/logs.${logTail(launchLog.file)}`,
  );
}

async function stop(pid, started) {
  if (!Number.isSafeInteger(pid) || pid <= 0) throw new Error('pid must be a positive integer.');
  if (typeof started !== 'string' || !/^[1-9]\d*$/u.test(started)) throw new Error('startedAt must be a FILETIME string.');
  const isTarget = () => readStudio(pid)?.startedAt === started;
  const signal = (name) => {
    try {
      process.kill(pid, name);
    } catch (error) {
      if (!isGone(error)) throw error;
    }
  };
  const studio = readStudio(pid);
  if (studio?.startedAt !== started) return {};
  log(`stop Studio pid ${pid}`);
  signal('SIGTERM');
  for (const deadline = Date.now() + STOP_GRACE_MS; Date.now() < deadline && isTarget();) await delay(POLL_MS);
  if (isTarget()) signal('SIGKILL');
  for (let tries = 0; tries < 20 && isTarget(); tries++) await delay(POLL_MS);
  if (!isTarget()) removeStaleLock(studio.argv);
  return {};
}

// Studio deletes the lock beside its place when it closes, but a killed Studio leaves it behind. Only folders no
// sandbox can write qualify, where a planted symlink cannot redirect the delete.
function removeStaleLock(argv) {
  const windowsPath = argv[argv.indexOf('--localPlaceFile') + 1];
  if (!argv.includes('--localPlaceFile') || !windowsPath?.startsWith('Z:\\')) return;
  const file = windowsPath.slice(2).replaceAll('\\', '/');
  if (!lockFolders.some((dir) => !relative(dir, file).startsWith('..'))) return;
  if (studioProcesses().some((other) => other.argv.includes(windowsPath))) return;
  const lock = `${file}.lock`;
  try {
    if (readFileSync(lock, 'utf8').split('\n')[1] !== 'RobloxStudioBeta') return;
    unlinkSync(lock);
    log(`removed ${lock}`);
  } catch (error) {
    if (error.code !== 'ENOENT') log(`could not remove ${lock}: ${error.message}`);
  }
}

function pipewireEnv() {
  return { ...process.env, XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR || `/run/user/${uid}` };
}

// The pid a process has in its innermost PID namespace, which Wine reports to X11 and PipeWire as its own.
function namespacePid(pid) {
  const line = /^NSpid:\s+(.+)$/mu.exec(readFileSync(`/proc/${pid}/status`, 'utf8'))?.[1];
  return line === undefined ? pid : Number(line.trim().split(/\s+/u).pop());
}

// The Flatpak instance a process runs in, named by its systemd scope, or undefined outside a Flatpak.
function flatpakInstance(pid) {
  return /app-flatpak-.+-(\d+)\.scope$/mu.exec(readFileSync(`/proc/${pid}/cgroup`, 'utf8'))?.[1];
}

// Studio's audio output streams for the pid Wine reports on its window. A stream qualifies only when a running Studio
// has that pid in its namespace and PipeWire saw the stream come from that Studio's Flatpak instance, so a sandboxed
// server can never tap a microphone or another application.
async function studioAudioStreams(windowPid) {
  if (!Number.isSafeInteger(windowPid) || windowPid <= 0) throw new Error('pid must be a positive integer.');
  const owners = studioProcesses().filter((studio) => {
    try {
      return namespacePid(studio.pid) === windowPid;
    } catch (error) {
      if (isGone(error)) return false;
      throw error;
    }
  });
  if (owners.length === 0) throw new Error(`No running Studio has pid ${windowPid}.`);
  if (owners.length > 1) {
    throw new Error(`${owners.length} Studio processes have pid ${windowPid} in their own Flatpaks, so the audio is ambiguous.`);
  }
  const instance = flatpakInstance(owners[0].pid);
  const { stdout } = await execFileAsync(PW_DUMP, [], { timeout: 10000, maxBuffer: 64 * 1024 * 1024, env: pipewireEnv() });
  const streams = [];
  for (const object of JSON.parse(stdout)) {
    const props = object?.info?.props;
    if (object?.type !== 'PipeWire:Interface:Node' || props?.['media.class'] !== 'Stream/Output/Audio') continue;
    if (Number(props['application.process.id']) !== windowPid) continue;
    const portal = props['pipewire.access.portal.instance_id'];
    if ((portal === undefined ? undefined : String(portal)) !== instance) continue;
    const serial = Number(props['object.serial']);
    if (Number.isSafeInteger(serial) && serial > 0) streams.push({ serial, name: String(props['media.name'] ?? props['node.name'] ?? '') });
  }
  return streams;
}

// Answers with a JSON header line, then relays raw 48 kHz stereo s16le until the client half closes or goes away.
async function streamAudio(socket, request) {
  const serial = request.serial;
  if (!Number.isSafeInteger(serial)) throw new Error('serial must be an integer.');
  const streams = await studioAudioStreams(request.pid);
  if (!streams.some((stream) => stream.serial === serial)) {
    throw new Error(`PipeWire stream ${serial} is not an audio output of Studio pid ${request.pid}.`);
  }
  if (audioSessions >= AUDIO_SESSIONS) throw new Error(`${AUDIO_SESSIONS} audio recordings are already running.`);
  audioSessions += 1;
  // Without these pw-record records the default microphone whenever its target is missing or goes away.
  const child = spawn(PW_RECORD, [
    '--target', String(serial), '--rate', '48000', '--channels', '2', '--format', 's16', '--latency', '20ms', '--raw',
    '-P', '{ node.dont-fallback = true node.dont-reconnect = true }', '-',
  ], { env: pipewireEnv(), stdio: ['ignore', 'pipe', 'pipe'] });
  let stderr = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk) => { stderr = (stderr + chunk).slice(-1000); });
  const stopRecording = () => {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
  };
  const limit = setTimeout(stopRecording, AUDIO_MAX_MS);
  child.once('close', () => {
    clearTimeout(limit);
    audioSessions -= 1;
  });
  socket.once('end', stopRecording);
  socket.once('close', stopRecording);
  let first;
  try {
    // The first samples show that pw-record linked to the stream, before the client is told it records.
    first = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`pw-record sent nothing within ${AUDIO_START_MS / 1000} s.`)), AUDIO_START_MS);
      child.stdout.once('data', (chunk) => {
        clearTimeout(timer);
        child.stdout.pause();
        resolve(chunk);
      });
      child.once('error', (error) => {
        clearTimeout(timer);
        reject(error);
      });
      child.once('exit', (code) => {
        clearTimeout(timer);
        reject(new Error(`pw-record exited with code ${code}: ${stderr.trim()}`));
      });
    });
  } catch (error) {
    stopRecording();
    throw error;
  }
  log(`audio of Studio pid ${request.pid}, stream ${serial}`);
  socket.write(`${JSON.stringify({ ok: true, rate: 48000, channels: 2 })}\n`);
  socket.write(first);
  child.stdout.pipe(socket);
}

async function handle(line) {
  const request = JSON.parse(line);
  switch (request?.op) {
    case 'launch': {
      const run = launchQueue.then(() => launch(request.args));
      launchQueue = run.catch(() => {});
      return run;
    }
    case 'list':
      return { processes: studioProcesses().map(publicProcess) };
    case 'stop':
      return stop(request.pid, request.startedAt);
    case 'audio-streams':
      return { streams: await studioAudioStreams(request.pid) };
    default:
      throw new Error(`Unknown op ${JSON.stringify(request?.op)}.`);
  }
}

let connections = 0;
let idle;
function watchIdle() {
  clearTimeout(idle);
  if (connections === 0) idle = setTimeout(() => process.exit(0), idleMs);
}

// Clients half-close after their request line, and the reply still has to go out.
const server = createServer({ allowHalfOpen: true }, (socket) => {
  connections += 1;
  watchIdle();
  socket.once('close', () => {
    connections -= 1;
    watchIdle();
  });
  let buffer = '';
  let handled = false;
  const answer = (line) => {
    if (handled) return;
    handled = true;
    let request;
    try {
      request = JSON.parse(line);
    } catch {
      request = undefined;
    }
    // A recording keeps the connection open for its samples instead of answering one line.
    if (request?.op === 'audio') {
      streamAudio(socket, request).catch((error) => {
        log(`error: ${error.message}`);
        if (!socket.destroyed) socket.end(`${JSON.stringify({ ok: false, error: error.message })}\n`);
      });
      return;
    }
    handle(line).then(
      (reply) => ({ ok: true, ...reply }),
      (error) => {
        log(`error: ${error.message}`);
        return { ok: false, error: error.message };
      },
    ).then((reply) => {
      if (!socket.destroyed) socket.end(`${JSON.stringify(reply)}\n`);
    });
  };
  socket.setEncoding('utf8');
  socket.on('error', () => {});
  socket.on('data', (chunk) => {
    buffer += chunk;
    if (buffer.length > MAX_REQUEST_BYTES) {
      handled = true;
      socket.end(`${JSON.stringify({ ok: false, error: 'Request over 64 KB.' })}\n`);
      return;
    }
    const newline = buffer.indexOf('\n');
    if (newline >= 0) answer(buffer.slice(0, newline));
  });
  socket.on('end', () => answer(buffer));
});

process.umask(0o077);
// The first descriptor systemd passes is the listening socket.
server.listen({ fd: 3 }, () => log('listening'));
watchIdle();
