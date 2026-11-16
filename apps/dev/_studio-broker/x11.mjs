// A minimal X11 client over the display's Unix socket: enough to find windows, read their pixels and map them.
// Wine draws Studio through X11, so its windows are X11 windows in a Wayland session too.
import { readFileSync } from 'node:fs';
import { connect } from 'node:net';
import { homedir } from 'node:os';

const ERROR_NAMES = {
  1: 'BadRequest', 2: 'BadValue', 3: 'BadWindow', 4: 'BadPixmap', 5: 'BadAtom', 8: 'BadMatch', 9: 'BadDrawable', 11: 'BadAlloc', 16: 'BadLength',
};
const BAD_MATCH = 8;
// Atoms every X server predefines.
const ATOM_WM_NAME = 39;
const ATOM_WM_CLASS = 67;
const OPCODE = {
  getWindowAttributes: 3, mapWindow: 8, getGeometry: 14, queryTree: 15, internAtom: 16, getProperty: 20, getInputFocus: 43, freePixmap: 54,
  getImage: 73, queryExtension: 98,
};
// Composite's minor opcodes, sent under the major opcode the server gives the extension.
const COMPOSITE = { queryVersion: 0, nameWindowPixmap: 6 };
const VIEWABLE = 2;
const REQUEST_TIMEOUT_MS = 10000;

// The X server's refusal of one request, which leaves the connection usable.
export class X11Error extends Error {
  constructor(code, opcode) {
    super(`X11 ${ERROR_NAMES[code] ?? `error ${code}`} on request ${opcode}`);
    this.code = code;
    this.opcode = opcode;
  }
}

const pad4 = (n) => (4 - (n % 4)) % 4;

// The MIT-MAGIC-COOKIE-1 for a display in an Xauthority file, whose fields are length prefixed and big endian.
function findXauthCookie(data, displayNumber) {
  let offset = 0;
  const field = () => {
    if (offset + 2 > data.length) throw new RangeError('truncated Xauthority entry');
    const length = data.readUInt16BE(offset);
    if (offset + 2 + length > data.length) throw new RangeError('truncated Xauthority entry');
    const value = data.subarray(offset + 2, offset + 2 + length);
    offset += 2 + length;
    return value;
  };
  try {
    while (offset < data.length) {
      offset += 2;
      field();
      const number = field().toString('latin1');
      const name = field().toString('latin1');
      const cookie = field();
      if (name === 'MIT-MAGIC-COOKIE-1' && (number === displayNumber || number === '')) return cookie;
    }
  } catch {
    return undefined;
  }
  return undefined;
}

// The parts of the connection setup this client needs: its id range, the first screen's root, pixel formats and visuals.
function parseSetup(data) {
  const vendorLength = data.readUInt16LE(16);
  const screenCount = data[20];
  const formatCount = data[21];
  if (screenCount < 1) throw new Error('The X server reported no screens.');
  const bitsPerPixel = new Map();
  let offset = 32 + vendorLength + pad4(vendorLength);
  for (let i = 0; i < formatCount; i++, offset += 8) bitsPerPixel.set(data[offset], data[offset + 1]);

  const root = data.readUInt32LE(offset);
  const depthCount = data[offset + 39];
  offset += 40;
  const visuals = new Map();
  for (let d = 0; d < depthCount; d++) {
    const visualCount = data.readUInt16LE(offset + 2);
    offset += 8;
    for (let v = 0; v < visualCount; v++, offset += 24) {
      visuals.set(data.readUInt32LE(offset), {
        redMask: data.readUInt32LE(offset + 8),
        greenMask: data.readUInt32LE(offset + 12),
        blueMask: data.readUInt32LE(offset + 16),
      });
    }
  }
  return { root, lsbFirst: data[22] === 0, bitsPerPixel, visuals, idBase: data.readUInt32LE(4), idMask: data.readUInt32LE(8) };
}

// The byte that holds a channel in a 32 bit pixel, for the 8 bit channel layouts every TrueColor visual in practice uses.
function channelByte(mask, lsbFirst) {
  for (let shift = 0; shift <= 24; shift += 8) {
    if (mask >>> 0 === (0xff << shift) >>> 0) return lsbFirst ? shift / 8 : 3 - shift / 8;
  }
  throw new Error(`Unsupported X11 visual channel mask 0x${mask.toString(16)}.`);
}

function packet(opcode, data, words, tail) {
  const length = 4 + words.length * 4 + (tail ? tail.length + pad4(tail.length) : 0);
  const out = Buffer.alloc(length);
  out[0] = opcode;
  out[1] = data;
  out.writeUInt16LE(length / 4, 2);
  words.forEach((word, i) => out.writeUInt32LE(word >>> 0, 4 + i * 4));
  tail?.copy(out, 4 + words.length * 4);
  return out;
}

// A name as InternAtom and QueryExtension take it: its length, two unused bytes, then the name.
function named(name) {
  const bytes = Buffer.from(name, 'latin1');
  const tail = Buffer.alloc(4 + bytes.length);
  tail.writeUInt16LE(bytes.length, 0);
  bytes.copy(tail, 4);
  return tail;
}

export class X11Connection {
  constructor(socket) {
    this.socket = socket;
    this.chunks = [];
    this.buffered = 0;
    this.sequence = 0;
    this.queue = Promise.resolve();
    this.lastId = 0;
    this.atoms = new Map();
    socket.on('data', (chunk) => {
      this.chunks.push(chunk);
      this.buffered += chunk.length;
      this.wake?.();
    });
    socket.on('error', (error) => this.fail(error));
    socket.on('close', () => this.fail(new Error('The X server closed the connection.')));
  }

  // Connects to the DISPLAY of env with the cookie from its XAUTHORITY, or from ~/.Xauthority.
  static async open(env) {
    const number = /^(?:unix)?:(\d+)(?:\.\d+)?$/u.exec(env.DISPLAY?.trim() ?? '')?.[1];
    if (number === undefined) throw new Error(`The session's DISPLAY ${JSON.stringify(env.DISPLAY ?? '')} is not a local X11 display.`);
    let cookie;
    try {
      cookie = findXauthCookie(readFileSync(env.XAUTHORITY || `${homedir()}/.Xauthority`), number);
    } catch {
      cookie = undefined;
    }

    const path = `/tmp/.X11-unix/X${number}`;
    const socket = connect(path);
    await new Promise((resolve, reject) => {
      socket.once('connect', resolve);
      socket.once('error', (error) => reject(new Error(`Could not connect to the X server at ${path}: ${error.message}`)));
    });
    const connection = new X11Connection(socket);

    const name = cookie ? Buffer.from('MIT-MAGIC-COOKIE-1') : Buffer.alloc(0);
    const auth = cookie ?? Buffer.alloc(0);
    const request = Buffer.alloc(12 + name.length + pad4(name.length) + auth.length + pad4(auth.length));
    request.write('l', 0, 'latin1');
    request.writeUInt16LE(11, 2);
    request.writeUInt16LE(name.length, 6);
    request.writeUInt16LE(auth.length, 8);
    name.copy(request, 12);
    auth.copy(request, 12 + name.length + pad4(name.length));
    socket.write(request);

    try {
      const head = await connection.read(8);
      const body = await connection.read(head.readUInt16LE(6) * 4);
      if (head[0] !== 1) {
        const reason = head[0] === 0 ? body.subarray(0, head[1]).toString('latin1') : 'more authentication required';
        throw new Error(`The X server refused the connection: ${reason.trim() || 'no reason given'}`);
      }
      connection.setup = parseSetup(body);
      return connection;
    } catch (error) {
      connection.close();
      throw error;
    }
  }

  // False once the socket failed or a reply ran late, after which replies no longer line up with requests.
  get usable() {
    return this.failure === undefined;
  }

  fail(error) {
    this.failure ??= error;
    this.socket.destroy();
    this.wake?.();
  }

  close() {
    this.fail(new Error('The X11 connection was closed.'));
  }

  async read(length) {
    if (length === 0) return Buffer.alloc(0);
    const deadline = Date.now() + REQUEST_TIMEOUT_MS;
    while (this.buffered < length) {
      if (this.failure) throw this.failure;
      const remaining = deadline - Date.now();
      if (remaining <= 0) {
        this.fail(new Error('The X server did not answer in time.'));
        continue;
      }
      await new Promise((resolve) => {
        const timer = setTimeout(resolve, remaining);
        this.wake = () => {
          clearTimeout(timer);
          resolve();
        };
      });
      this.wake = undefined;
    }
    if (this.chunks.length > 1) this.chunks = [Buffer.concat(this.chunks)];
    const all = this.chunks[0];
    const rest = all.subarray(length);
    this.chunks = rest.length > 0 ? [rest] : [];
    this.buffered -= length;
    return all.subarray(0, length);
  }

  // Sends one request and returns its whole reply. Requests run one at a time, so replies cannot interleave. A
  // request that has no reply goes first as before, and its error is raised as this request's.
  request(request, before) {
    const run = async () => {
      let beforeSequence;
      if (before) {
        this.sequence = (this.sequence + 1) & 0xffff;
        beforeSequence = this.sequence;
        this.socket.write(before);
      }
      this.sequence = (this.sequence + 1) & 0xffff;
      const sequence = this.sequence;
      this.socket.write(request);
      for (;;) {
        const head = await this.read(32);
        const kind = head[0] & 0x7f;
        if (kind === 0) {
          const failed = head.readUInt16LE(2);
          if (failed !== sequence && failed !== beforeSequence) continue;
          throw new X11Error(head[1], head[10]);
        }
        if (kind === 1) {
          const body = await this.read(head.readUInt32LE(4) * 4);
          if (head.readUInt16LE(2) !== sequence) continue;
          return Buffer.concat([head, body]);
        }
        // An event nobody asked for. GenericEvent (35) carries a body like a reply.
        if (kind === 35) await this.read(head.readUInt32LE(4) * 4);
      }
    };
    const result = this.queue.then(run, run);
    this.queue = result.catch(() => undefined);
    return result;
  }

  // An atom some client already made, or 0 when none did.
  async existingAtom(name) {
    let atom = this.atoms.get(name);
    if (!atom) {
      atom = (await this.request(packet(OPCODE.internAtom, 1, [], named(name)))).readUInt32LE(8);
      if (atom) this.atoms.set(name, atom);
    }
    return atom;
  }

  // A property's raw bytes, or undefined when the window does not have it.
  async getProperty(window, property, maxBytes = 4096) {
    const reply = await this.request(packet(OPCODE.getProperty, 0, [window, property, 0, 0, Math.ceil(maxBytes / 4)]));
    if (reply.readUInt32LE(8) === 0) return undefined;
    const format = reply[1];
    return { format, data: reply.subarray(32, 32 + reply.readUInt32LE(16) * (format / 8)) };
  }

  async title(window) {
    const netWmName = await this.existingAtom('_NET_WM_NAME');
    const utf8 = netWmName ? await this.getProperty(window, netWmName) : undefined;
    return utf8 ? utf8.data.toString('utf8') : (await this.getProperty(window, ATOM_WM_NAME))?.data.toString('latin1') ?? '';
  }

  // The instance and class names of WM_CLASS, joined by a space.
  async className(window) {
    const wmClass = (await this.getProperty(window, ATOM_WM_CLASS))?.data.toString('latin1') ?? '';
    return wmClass.split('\0').filter(Boolean).join(' ');
  }

  // The process that owns the window, as its _NET_WM_PID says.
  async processId(window) {
    const atom = await this.existingAtom('_NET_WM_PID');
    const property = atom ? await this.getProperty(window, atom) : undefined;
    return property && property.format === 32 && property.data.length >= 4 ? property.data.readUInt32LE(0) : undefined;
  }

  async queryTree(window) {
    const reply = await this.request(packet(OPCODE.queryTree, 0, [window]));
    return Array.from({ length: reply.readUInt16LE(16) }, (_, i) => reply.readUInt32LE(32 + i * 4));
  }

  async getGeometry(window) {
    const reply = await this.request(packet(OPCODE.getGeometry, 0, [window]));
    return { width: reply.readUInt16LE(16), height: reply.readUInt16LE(18) };
  }

  // A minimized window is unmapped, and the X server keeps no pixels for it.
  async viewable(window) {
    return (await this.request(packet(OPCODE.getWindowAttributes, 0, [window])))[26] === VIEWABLE;
  }

  // Asks for a minimized window to be shown again. Mapping an iconic window is the ICCCM way back to its normal state,
  // which the window manager carries out without making it the active window. MapWindow has no reply, so
  // GetInputFocus after it waits until the server handled it.
  async mapWindow(window) {
    await this.request(packet(OPCODE.getInputFocus, 0, []), packet(OPCODE.mapWindow, 0, [window]));
  }

  // The pixels of a window or a pixmap in a rectangle of its own coordinates, 4 bytes each, with the byte offsets of
  // red, green and blue in a pixel. A pixmap has no visual of its own, so it is read in the visual of its window.
  async getImage(drawable, x, y, width, height, visualId) {
    const request = packet(OPCODE.getImage, 2, [drawable, 0, 0, 0xffffffff]);
    request.writeInt16LE(x, 8);
    request.writeInt16LE(y, 10);
    request.writeUInt16LE(width, 12);
    request.writeUInt16LE(height, 14);
    const reply = await this.request(request);
    const depth = reply[1];
    const visual = this.setup.visuals.get(reply.readUInt32LE(8) || (visualId ?? 0));
    const bits = this.setup.bitsPerPixel.get(depth);
    if (!visual || bits !== 32) throw new Error(`Unsupported X11 pixel format (depth ${depth}, ${bits ?? '?'} bits per pixel).`);
    if (reply.length - 32 < width * height * 4) throw new Error('The X server returned a short image.');
    const { lsbFirst } = this.setup;
    return {
      data: reply.subarray(32, 32 + width * height * 4),
      layout: { r: channelByte(visual.redMask, lsbFirst), g: channelByte(visual.greenMask, lsbFirst), b: channelByte(visual.blueMask, lsbFirst) },
    };
  }

  // The window's pixels as the window drew them. Xwayland and compositing window managers keep every window in a
  // pixmap through Composite, which holds the whole window even where another window covers it, while reading the
  // window itself gives whatever is on top there. Without that pixmap the window is read where it shows.
  async getWindowImage(window, x, y, width, height) {
    const composite = await this.compositeOpcode();
    if (composite === undefined) return this.getImage(window, x, y, width, height);
    const pixmap = this.allocateId();
    try {
      await this.request(packet(OPCODE.getInputFocus, 0, []), packet(composite, COMPOSITE.nameWindowPixmap, [window, pixmap]));
    } catch (error) {
      // BadMatch: nothing redirects the window, or it is not viewable, which reading the window itself reports.
      if (error instanceof X11Error && error.code === BAD_MATCH) return this.getImage(window, x, y, width, height);
      throw error;
    }
    try {
      const visual = (await this.request(packet(OPCODE.getWindowAttributes, 0, [window]))).readUInt32LE(8);
      return await this.getImage(pixmap, x, y, width, height, visual);
    } finally {
      await this.request(packet(OPCODE.getInputFocus, 0, []), packet(OPCODE.freePixmap, 0, [pixmap]));
    }
  }

  // Composite's major opcode, or undefined when the server lacks the extension or a version with window pixmaps.
  compositeOpcode() {
    this.composite ??= (async () => {
      const extension = await this.request(packet(OPCODE.queryExtension, 0, [], named('Composite')));
      if (extension[8] !== 1) return undefined;
      const major = extension[9];
      // The extension takes no other request before the client says which version it speaks.
      const version = await this.request(packet(major, COMPOSITE.queryVersion, [0, 4]));
      return version.readUInt32LE(8) > 0 || version.readUInt32LE(12) >= 2 ? major : undefined;
    })();
    return this.composite;
  }

  // A new id from the range the server set aside for this client's resources.
  allocateId() {
    const { idBase, idMask } = this.setup;
    const shift = 31 - Math.clz32(idMask & -idMask);
    this.lastId = (this.lastId + 1) & (idMask >>> shift);
    return (idBase | (this.lastId << shift)) >>> 0;
  }
}
