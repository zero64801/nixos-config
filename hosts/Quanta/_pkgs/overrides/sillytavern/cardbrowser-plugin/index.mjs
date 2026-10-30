// Card Browser relay: the server half of the Card Browser extension.
// A port of Marinara Engine's bot-browser routes (AGPL-3.0), minus its corsproxy.io fallback.
// It only reaches the card sites below, over https, and returns their JSON or validated images.

import { randomUUID } from 'node:crypto';

export const info = {
    id: 'cardbrowser',
    name: 'Card Browser',
    description: 'Relays searches, details and card downloads from character card sites for the Card Browser extension.',
};

const BROWSER_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const JSON_MAX_BYTES = 8 * 1024 * 1024;
const IMAGE_MAX_BYTES = 64 * 1024 * 1024;
const CARD_MAX_BYTES = 256 * 1024 * 1024;
const PAGE_MAX_BYTES = 8 * 1024 * 1024;
const MAX_REDIRECTS = 3;

const CHUB_API = 'https://api.chub.ai';
const CHUB_AVATARS = 'https://avatars.charhub.io';
const JANNY_SEARCH_URL = 'https://search.jannyai.com/multi-search';
const JANNY_IMAGE_BASE = 'https://image.jannyai.com/bot-avatars/';
const JANNY_SITE = 'https://jannyai.com';
const JANNY_API_SITE = 'https://api.jannyai.com';
const JANNY_DOWNLOAD_API = 'https://api.jannyai.com/api/v1/download';
const JANNY_FALLBACK_TOKEN = '88a6463b66e04fb07ba87ee3db06af337f492ce511d93df6e2d2968cb2ff2b30';
const PYG_API = 'https://server.pygmalion.chat/galatea.v1.PublicCharacterService';
const PYG_ASSETS = 'https://assets.pygmalion.chat';
const WYVERN_API = 'https://api.wyvern.chat';
const WYVERN_IMAGES = 'https://imagedelivery.net';
const DATACAT_API = 'https://datacat.run';
const DATACAT_IMAGES = 'https://ella.janitorai.com/bot-avatars/';
const DATACAT_MIN_TOKENS = 889;

class HttpError extends Error {
    constructor(status, message, extra = {}) {
        super(message);
        this.status = status;
        this.extra = extra;
    }
}

function hostAllowed(hostname, hosts) {
    return hosts.some(h => h.startsWith('.') ? hostname.endsWith(h) || hostname === h.slice(1) : hostname === h);
}

async function readLimited(res, maxBytes) {
    const declared = Number(res.headers.get('content-length'));
    if (declared > maxBytes) throw new HttpError(502, 'Upstream response is too large');
    const reader = res.body?.getReader();
    if (!reader) return Buffer.alloc(0);
    const chunks = [];
    let total = 0;
    for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        total += value.byteLength;
        if (total > maxBytes) {
            await reader.cancel();
            throw new HttpError(502, 'Upstream response is too large');
        }
        chunks.push(value);
    }
    return Buffer.concat(chunks);
}

/**
 * fetch() restricted to https and the given hosts, redirects included, with a body size cap.
 * Node's fetch honours HTTPS_PROXY when NODE_USE_ENV_PROXY is set, so this rides the same tunnel as the server.
 */
async function fetchAllowed(url, { hosts, method = 'GET', headers = {}, body, maxBytes = JSON_MAX_BYTES, timeoutMs = 30_000 } = {}) {
    let target = new URL(url);
    const signal = AbortSignal.timeout(timeoutMs);
    for (let hop = 0; ; hop++) {
        if (target.protocol !== 'https:' || !hostAllowed(target.hostname, hosts)) {
            throw new HttpError(400, `Refused host ${target.hostname || '(none)'}`);
        }
        const res = await fetch(target, { method, headers, body, redirect: 'manual', signal });
        if (res.status >= 300 && res.status < 400 && res.headers.get('location')) {
            if (hop >= MAX_REDIRECTS) throw new HttpError(502, 'Too many redirects');
            target = new URL(res.headers.get('location'), target);
            method = method === 'POST' && res.status !== 307 && res.status !== 308 ? 'GET' : method;
            if (method === 'GET') body = undefined;
            continue;
        }
        return { res, buf: await readLimited(res, maxBytes) };
    }
}

async function fetchJson(url, options = {}) {
    const headers = { Accept: 'application/json', 'User-Agent': BROWSER_UA, ...options.headers };
    const { res, buf } = await fetchAllowed(url, { ...options, headers });
    if (!res.ok) throw new HttpError(res.status >= 500 ? 502 : res.status, `Upstream ${res.status}: ${buf.toString('utf8').slice(0, 200)}`, { upstreamStatus: res.status });
    try {
        return JSON.parse(buf.toString('utf8'));
    } catch {
        throw new HttpError(502, 'Upstream sent invalid JSON');
    }
}

function imageType(buf) {
    if (buf.length >= 8 && buf.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) return 'image/png';
    if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg';
    if (buf.length >= 6 && /^GIF8[79]a$/.test(buf.subarray(0, 6).toString('latin1'))) return 'image/gif';
    if (buf.length >= 12 && buf.subarray(0, 4).toString('latin1') === 'RIFF' && buf.subarray(8, 12).toString('latin1') === 'WEBP') return 'image/webp';
    if (buf.length >= 12 && buf.subarray(4, 8).toString('latin1') === 'ftyp' && /^avi[fs]$/.test(buf.subarray(8, 12).toString('latin1'))) return 'image/avif';
    return null;
}

async function fetchImage(url, hosts, headers = {}) {
    const { res, buf } = await fetchAllowed(url, { hosts, maxBytes: IMAGE_MAX_BYTES, headers: { 'User-Agent': BROWSER_UA, ...headers } });
    if (!res.ok) return null;
    const type = imageType(buf);
    if (!type) throw new HttpError(415, 'Unsupported image content');
    return { buf, type };
}

function sendImage(res, image) {
    if (!image) return res.status(404).json({ error: 'Image not found' });
    return res.set('Content-Type', image.type).set('Cache-Control', 'public, max-age=86400').send(image.buf);
}

function encodePath(path) {
    return String(path).split('/').map(encodeURIComponent).join('/');
}

/** Express 4 handlers do not catch rejected promises, so every route goes through this. */
function route(handler) {
    return async (req, res) => {
        try {
            const result = await handler(req, res);
            if (result !== undefined && !res.headersSent) res.json(result);
        } catch (err) {
            if (res.headersSent) return;
            const status = err instanceof HttpError ? err.status : err?.name === 'TimeoutError' ? 504 : 502;
            res.status(status).json({ error: err?.message || 'Request failed', ...(err?.extra ?? {}) });
        }
    };
}

// ── JannyAI search token, scraped from its public bundle ──

let jannyToken = '';
let jannyTokenFallback = false;
let jannyTokenAt = 0;
let jannyTokenInFlight = null;

async function fetchJannyText(path) {
    try {
        const { res, buf } = await fetchAllowed(`${JANNY_SITE}${path}`, {
            hosts: ['jannyai.com'],
            maxBytes: PAGE_MAX_BYTES,
            timeoutMs: 15_000,
            headers: { 'User-Agent': BROWSER_UA, Accept: 'text/html,application/xhtml+xml,*/*' },
        });
        return res.ok ? buf.toString('utf8') : null;
    } catch {
        return null;
    }
}

async function scrapeJannyToken() {
    const html = await fetchJannyText('/characters/search');
    if (html) {
        let configPath = null;
        const direct = html.match(/client-config\.[a-zA-Z0-9_-]+\.js/);
        if (direct) configPath = `/_astro/${direct[0]}`;
        else {
            const page = html.match(/SearchPage\.[a-zA-Z0-9_-]+\.js/);
            const pageJs = page ? await fetchJannyText(`/_astro/${page[0]}`) : null;
            const imported = pageJs?.match(/client-config\.[a-zA-Z0-9_-]+\.js/);
            if (imported) configPath = `/_astro/${imported[0]}`;
        }
        const configJs = configPath ? await fetchJannyText(configPath) : null;
        const token = configJs?.match(/"([a-f0-9]{64})"/)?.[1];
        if (token) return { token, fallback: false };
    }
    return { token: JANNY_FALLBACK_TOKEN, fallback: true };
}

async function getJannyToken(force) {
    const ttl = jannyTokenFallback ? 60_000 : 5 * 60_000;
    if (jannyToken && !force && Date.now() - jannyTokenAt < ttl) return jannyToken;
    if (!jannyTokenInFlight) {
        jannyTokenInFlight = scrapeJannyToken().then(({ token, fallback }) => {
            jannyToken = token;
            jannyTokenFallback = fallback;
            jannyTokenAt = Date.now();
            return token;
        }).finally(() => { jannyTokenInFlight = null; });
    }
    return jannyTokenInFlight;
}

function jannySearchHeaders(token) {
    return {
        Accept: '*/*',
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
        Origin: JANNY_SITE,
        Referer: `${JANNY_SITE}/`,
        'User-Agent': BROWSER_UA,
        'x-meilisearch-client': 'Meilisearch instant-meilisearch (v0.19.0) ; Meilisearch JavaScript (v0.41.0)',
    };
}

function decodeAstroValue(value) {
    if (!Array.isArray(value)) return value;
    const [type, data] = value;
    if (type === 0 && data && typeof data === 'object' && !Array.isArray(data)) {
        return Object.fromEntries(Object.entries(data).map(([k, v]) => [k, decodeAstroValue(v)]));
    }
    if (type === 1 && Array.isArray(data)) return data.map(decodeAstroValue);
    return data;
}

function readQuotedAttribute(tag, name) {
    const prefix = `${name}="`;
    let from = 0;
    for (;;) {
        const start = tag.indexOf(prefix, from);
        if (start < 0) return null;
        if (start > 0 && !/\s/.test(tag[start - 1])) {
            from = start + prefix.length;
            continue;
        }
        const end = tag.indexOf('"', start + prefix.length);
        return end < 0 ? null : tag.slice(start + prefix.length, end);
    }
}

/** Finds the character props of JannyAI's Astro page without backtracking regexes over the whole page. */
function extractJannyCharacterProps(html) {
    let from = 0;
    let fallback = null;
    for (;;) {
        const start = html.indexOf('<astro-island', from);
        if (start < 0) break;
        const end = html.indexOf('>', start);
        if (end < 0) break;
        const tag = html.slice(start, end + 1);
        const props = readQuotedAttribute(tag, 'props');
        if (props !== null) {
            if (readQuotedAttribute(tag, 'component-export') === 'CharacterButtons') return props;
            if (fallback === null && props.includes('character')) fallback = props;
        }
        from = end + 1;
    }
    return fallback;
}

function decodeEntities(value) {
    const map = { '&quot;': '"', '&amp;': '&', '&lt;': '<', '&gt;': '>', '&#39;': "'" };
    return value.replace(/&(?:quot|amp|lt|gt|#39);/g, e => map[e] ?? e);
}

// ── Pygmalion login, kept in memory like Marinara does ──

let pygToken = '';
const PYG_TOKEN_PATTERN = /^[A-Za-z0-9._~+/=-]{1,8192}$/;
const PYG_FAILURES = {
    unreachable: { status: 502, error: "Couldn't reach Pygmalion" },
    rejected: { status: 400, error: 'Pygmalion rejected the token' },
    busy: { status: 503, error: 'Pygmalion is busy, try again' },
};

function pygFailureFor(status) {
    if (status === 401 || status === 403) return 'rejected';
    return status === 408 || status === 429 || status >= 500 ? 'busy' : 'unreachable';
}

async function checkPygToken(token) {
    try {
        const { res } = await fetchAllowed(`${PYG_API}/CharacterSearch`, {
            hosts: ['server.pygmalion.chat'],
            method: 'POST',
            headers: { 'Content-Type': 'application/json', Accept: 'application/json', Authorization: `Bearer ${token}`, 'User-Agent': BROWSER_UA },
            body: JSON.stringify({ query: '', orderBy: 'downloads', orderDescending: true, pageSize: 1, page: 0, includeSensitive: true }),
            timeoutMs: 15_000,
            maxBytes: 1024 * 1024,
        });
        return res.ok ? null : pygFailureFor(res.status);
    } catch {
        return 'unreachable';
    }
}

async function pygAuthed(res, procedure, message) {
    const token = pygToken;
    try {
        return await fetchJson(`${PYG_API}/${procedure}`, {
            hosts: ['server.pygmalion.chat'],
            method: 'POST',
            headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
            body: JSON.stringify(message),
        });
    } catch (err) {
        const upstream = err?.extra?.upstreamStatus;
        if (upstream === 401) {
            if (pygToken === token) pygToken = '';
            res.status(401).json({ error: 'Pygmalion session expired', reason: 'rejected', sessionExpired: true });
            return undefined;
        }
        const failure = typeof upstream === 'number' ? pygFailureFor(upstream) : 'unreachable';
        res.status(PYG_FAILURES[failure].status).json({ error: PYG_FAILURES[failure].error, reason: failure });
        return undefined;
    }
}

// ── DataCat session ──

let dcToken = '';
let dcTokenInFlight = null;

function dcHeaders(token) {
    return { Accept: 'application/json', 'User-Agent': BROWSER_UA, Origin: DATACAT_API, Referer: `${DATACAT_API}/`, 'X-Session-Token': token };
}

async function mintDatacatToken() {
    const data = await fetchJson(`${DATACAT_API}/api/liberator/identify`, {
        hosts: ['datacat.run'],
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Origin: DATACAT_API, Referer: `${DATACAT_API}/` },
        body: JSON.stringify({ deviceToken: randomUUID() }),
        timeoutMs: 20_000,
    });
    if (!data?.success || !data?.sessionToken) throw new HttpError(502, 'DataCat did not issue a session');
    return data.sessionToken;
}

async function getDatacatToken() {
    if (dcToken) return dcToken;
    if (!dcTokenInFlight) {
        dcTokenInFlight = mintDatacatToken().then(t => (dcToken = t)).finally(() => { dcTokenInFlight = null; });
    }
    return dcTokenInFlight;
}

async function dcFetch(path, maxBytes = JSON_MAX_BYTES) {
    const request = async () => fetchJson(`${DATACAT_API}${path}`, { hosts: ['datacat.run'], maxBytes, headers: dcHeaders(await getDatacatToken()) });
    try {
        return await request();
    } catch (err) {
        if (err?.extra?.upstreamStatus !== 401) throw err;
        dcToken = '';
        return request();
    }
}

function splitIds(value) {
    return String(value ?? '').split(',').map(s => s.trim()).filter(Boolean);
}

export async function init(router) {
    router.get('/health', (_req, res) => res.json({ ok: true }));

    // ── ChubAI ──
    router.get('/chub/search', route(async (req) => {
        const q = req.query;
        const nsfw = q.nsfw ?? 'true';
        const params = new URLSearchParams({
            search: q.q ?? '', first: '48', page: q.page ?? '1', namespace: 'characters', nsfw, nsfl: nsfw,
            nsfw_only: 'false', chub: 'true', count: 'true', include_forks: 'true', venus: 'false', min_tokens: q.min_tokens ?? '50',
        });
        if (q.sort && q.sort !== 'default') params.set('sort', q.sort);
        if (q.asc === 'true') params.set('asc', 'true');
        if (q.max_days_ago && q.max_days_ago !== '0') params.set('max_days_ago', q.max_days_ago);
        if (q.special_mode) params.set('special_mode', q.special_mode);
        if (q.username) params.set('username', q.username);
        if (q.max_tokens) params.set('max_tokens', q.max_tokens);
        if (q.tags) params.set('topics', q.tags);
        if (q.excludeTags) params.set('excludetopics', q.excludeTags);
        for (const key of ['require_images', 'require_lore', 'require_expressions', 'require_alternate_greetings']) {
            if (q[key] === 'true') params.set(key, 'true');
        }
        return fetchJson(`${CHUB_API}/search?${params}`, { hosts: ['api.chub.ai'] });
    }));
    router.get('/chub/character/*', route(async (req) => {
        const path = req.params[0];
        if (!path) throw new HttpError(400, 'Missing character path');
        return fetchJson(`${CHUB_API}/api/characters/${encodeURI(path)}?full=true&nocache=${Date.now()}`, { hosts: ['api.chub.ai'], headers: { 'Cache-Control': 'no-cache' } });
    }));
    router.get('/chub/download/*', route(async (req, res) => {
        const path = req.params[0];
        if (!path) throw new HttpError(400, 'Missing character path');
        const { res: up, buf } = await fetchAllowed(`${CHUB_AVATARS}/avatars/${encodeURI(path)}/chara_card_v2.png`, {
            hosts: ['avatars.charhub.io'], maxBytes: CARD_MAX_BYTES, timeoutMs: 60_000, headers: { 'User-Agent': BROWSER_UA },
        });
        if (!up.ok) throw new HttpError(502, `Download failed: ${up.status}`);
        if (imageType(buf) !== 'image/png') throw new HttpError(502, 'Downloaded card is not a PNG image');
        res.set('Content-Type', 'image/png').send(buf);
    }));
    router.get('/chub/avatar/*', route(async (req, res) => {
        const path = req.params[0];
        if (!path) throw new HttpError(400, 'Missing avatar path');
        const sources = req.query.full === '1' ? ['chara_card_v2.png', 'avatar.webp'] : ['avatar.webp', 'chara_card_v2.png'];
        for (const file of sources) {
            const image = await fetchImage(`${CHUB_AVATARS}/avatars/${encodeURI(path)}/${file}`, ['avatars.charhub.io']);
            if (image) return sendImage(res, image);
        }
        return sendImage(res, null);
    }));

    // ── JannyAI ──
    router.get('/janny/token', route(async (req) => ({ token: await getJannyToken(req.query.force === '1' || req.query.force === 'true') })));
    router.get('/janny/search', route(async (req) => {
        const q = req.query;
        const filters = [`totalToken >= ${parseInt(q.min_tokens) || 29}`, `totalToken <= ${parseInt(q.max_tokens) || 100000}`];
        if (q.nsfw !== 'true') filters.push('isNsfw = false');
        if (q.showLowQuality !== 'true') filters.push('isLowQuality = false');
        const tagIds = splitIds(q.tagIds);
        if (tagIds.length) filters.push(tagIds.map(id => `tagIds = ${id}`).join(' AND '));
        const sortMap = { newest: ['createdAtStamp:desc'], oldest: ['createdAtStamp:asc'], tokens_desc: ['totalToken:desc'], tokens_asc: ['totalToken:asc'], relevant: [] };
        const sort = sortMap[q.sort] ?? sortMap.newest;
        const body = {
            queries: [{
                indexUid: 'janny-characters', q: q.q ?? '', facets: ['isLowQuality', 'isNsfw', 'tagIds', 'totalToken'],
                attributesToCrop: ['description:300'], cropMarker: '...', filter: filters, attributesToHighlight: ['name', 'description'],
                highlightPreTag: '__ais-highlight__', highlightPostTag: '__/ais-highlight__',
                hitsPerPage: parseInt(q.limit) || 80, page: parseInt(q.page) || 1, ...(sort.length ? { sort } : {}),
            }],
        };
        const token = await getJannyToken(false);
        try {
            return await fetchJson(JANNY_SEARCH_URL, { hosts: ['search.jannyai.com'], method: 'POST', headers: jannySearchHeaders(token), body: JSON.stringify(body) });
        } catch (err) {
            const upstream = err?.extra?.upstreamStatus;
            if (upstream === 401 || upstream === 403) {
                jannyToken = '';
                throw new HttpError(502, 'JannyAI is blocking server requests (Cloudflare). Try again later.');
            }
            throw err;
        }
    }));
    router.get('/janny/download/:id', route(async (req, res) => {
        const id = String(req.params.id ?? '').trim();
        if (!id || id.length > 256) throw new HttpError(400, 'Invalid JannyAI character ID');
        const payload = await fetchJson(JANNY_DOWNLOAD_API, {
            hosts: ['api.jannyai.com'], method: 'POST', maxBytes: 128 * 1024, timeoutMs: 45_000,
            headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ characterId: id }),
        });
        if (payload?.status !== 'ok' || typeof payload.downloadUrl !== 'string') {
            throw new HttpError(502, 'JannyAI could not provide the complete character card. Please try again later.');
        }
        const cardUrl = new URL(payload.downloadUrl);
        const { res: up, buf } = await fetchAllowed(cardUrl, {
            hosts: [cardUrl.hostname], maxBytes: CARD_MAX_BYTES, timeoutMs: 45_000, headers: { Accept: 'image/png,application/octet-stream;q=0.9' },
        });
        if (!up.ok || imageType(buf) !== 'image/png') throw new HttpError(502, 'JannyAI returned an invalid character card');
        res.set('Content-Type', 'image/png').send(buf);
    }));
    router.get('/janny/character/:id', route(async (req) => {
        const id = req.params.id;
        const slug = String(req.query.slug || 'character');
        const usable = html => html.length >= 1000 && !html.includes('Just a moment') && !html.includes('cf-challenge')
            && !html.includes('challenge-platform') && html.includes('astro-island');
        let html = '';
        for (const url of [`${JANNY_API_SITE}/characters/${id}_${slug}`, `${JANNY_SITE}/characters/${id}_${slug}`]) {
            try {
                const { res, buf } = await fetchAllowed(url, {
                    hosts: ['jannyai.com', 'api.jannyai.com'], maxBytes: PAGE_MAX_BYTES,
                    headers: { Accept: 'text/html,application/xhtml+xml,*/*', 'User-Agent': BROWSER_UA, Referer: `${JANNY_SITE}/` },
                });
                const text = res.ok ? buf.toString('utf8') : '';
                if (usable(text)) {
                    html = text;
                    break;
                }
            } catch { /* next */ }
        }
        if (!html) throw new HttpError(404, 'Could not fetch character page (Cloudflare blocked)');
        const props = extractJannyCharacterProps(html);
        if (props === null) throw new HttpError(404, 'Could not parse character data from page');
        const character = decodeAstroValue(JSON.parse(decodeEntities(props)).character);
        if (!character) throw new HttpError(404, 'No character data found in page');
        const creator = html.match(/Creator:\s*(?:<\/[^>]+>\s*)?<a[^>]*>@?([^<]+)<\/a>/);
        if (creator) character.creatorUsername = creator[1].trim();
        return { character, success: true };
    }));
    router.get('/janny/avatar/*', route(async (req, res) => {
        if (!req.params[0]) throw new HttpError(400, 'Missing avatar path');
        return sendImage(res, await fetchImage(`${JANNY_IMAGE_BASE}${encodePath(req.params[0])}`, ['image.jannyai.com']));
    }));

    // ── Pygmalion ──
    router.post('/pygmalion/set-token', route(async (req, res) => {
        let value = typeof req.body?.token === 'string' ? req.body.token.trim() : '';
        if (value.toLowerCase().startsWith('bearer ')) value = value.slice(7).trim();
        if (!PYG_TOKEN_PATTERN.test(value)) {
            res.status(400).json({ error: "Paste only the token. It can't contain spaces or line breaks.", reason: 'invalid', active: !!pygToken });
            return undefined;
        }
        const failure = await checkPygToken(value);
        if (failure) {
            res.status(PYG_FAILURES[failure].status).json({ error: PYG_FAILURES[failure].error, reason: failure, active: !!pygToken });
            return undefined;
        }
        pygToken = value;
        return { ok: true, active: true };
    }));
    router.get('/pygmalion/validate', route(async () => {
        if (!pygToken) return { valid: false, reason: 'no token stored' };
        const token = pygToken;
        const failure = await checkPygToken(token);
        if (!failure) return { valid: true };
        if (failure === 'rejected' && pygToken === token) pygToken = '';
        return { valid: false, reason: PYG_FAILURES[failure].error };
    }));
    router.post('/pygmalion/logout', route(async () => {
        pygToken = '';
        return { ok: true };
    }));
    router.get('/pygmalion/session', route(async () => ({ active: !!pygToken, hasToken: !!pygToken })));
    router.get('/pygmalion/search', route(async (req, res) => {
        const q = req.query;
        const message = {
            query: q.q ?? '', orderBy: q.orderBy ?? 'downloads', orderDescending: (q.orderDescending ?? 'true') === 'true',
            pageSize: parseInt(q.pageSize) || 48, page: parseInt(q.page) || 0,
        };
        if (q.tagsInclude) message.tagsNamesInclude = splitIds(q.tagsInclude);
        if (q.tagsExclude) message.tagsNamesExclude = splitIds(q.tagsExclude);
        if (q.includeSensitive === 'true' && pygToken) {
            message.includeSensitive = true;
            return pygAuthed(res, 'CharacterSearch', message);
        }
        const params = new URLSearchParams({ connect: 'v1', encoding: 'json', message: JSON.stringify(message) });
        return fetchJson(`${PYG_API}/CharacterSearch?${params}`, { hosts: ['server.pygmalion.chat'] });
    }));
    router.get('/pygmalion/character', route(async (req, res) => {
        const { id, versionId } = req.query;
        if (!id) throw new HttpError(400, 'Missing character id');
        const message = { characterMetaId: String(id) };
        if (versionId) message.characterVersionId = String(versionId);
        if (pygToken) return pygAuthed(res, 'Character', message);
        const params = new URLSearchParams({ connect: 'v1', encoding: 'json', message: JSON.stringify(message) });
        return fetchJson(`${PYG_API}/Character?${params}`, { hosts: ['server.pygmalion.chat'] });
    }));
    router.get('/pygmalion/avatar/*', route(async (req, res) => {
        const raw = req.params[0];
        if (!raw) throw new HttpError(400, 'Missing asset path');
        const url = URL.parse(raw.startsWith('http') ? raw : `${PYG_ASSETS}/${raw}`);
        if (!url || url.protocol !== 'https:' || !hostAllowed(url.hostname, ['.pygmalion.chat'])) {
            throw new HttpError(400, 'Avatar must come from Pygmalion');
        }
        return sendImage(res, await fetchImage(url, [url.hostname]));
    }));

    // ── Wyvern ──
    router.get('/wyvern/search', route(async (req) => {
        const q = req.query;
        const params = new URLSearchParams({ limit: q.limit ?? '48', page: q.page ?? '1' });
        if (q.tags) params.set('tags', q.tags);
        if (q.q) params.set('q', q.q);
        else {
            params.set('sort', q.sort ?? 'popular');
            params.set('order', q.order ?? 'DESC');
        }
        if (q.rating) params.set('rating', q.rating);
        return fetchJson(`${WYVERN_API}/exploreSearch/characters?${params}`, { hosts: ['api.wyvern.chat'] });
    }));
    router.get('/wyvern/character/:id', route(async (req) => fetchJson(`${WYVERN_API}/characters/${encodeURIComponent(req.params.id)}`, { hosts: ['api.wyvern.chat'] })));
    router.get('/wyvern/avatar/*', route(async (req, res) => {
        const raw = req.params[0];
        if (!raw) throw new HttpError(400, 'Missing image path');
        const url = new URL(raw.startsWith('http') ? raw : raw.includes('imagedelivery.net') ? `https://${raw}` : `${WYVERN_IMAGES}/${raw}`);
        if (!hostAllowed(url.hostname, ['.imagedelivery.net'])) throw new HttpError(400, 'Invalid avatar host');
        return sendImage(res, await fetchImage(url, [url.hostname]));
    }));

    // ── DataCat ──
    router.get('/datacat/recent', route(async (req) => {
        const q = req.query;
        const params = new URLSearchParams({ limit: q.limit ?? '80', offset: q.offset ?? '0', summary: '1', minTotalTokens: q.min_tokens ?? String(DATACAT_MIN_TOKENS) });
        const ids = splitIds(q.tagIds);
        if (ids.length) params.set('tagIds', ids.join(','));
        if (String(q.q ?? '').trim()) params.set('search', String(q.q).trim());
        return dcFetch(`/api/characters/recent-public?${params}`);
    }));
    router.get('/datacat/fresh', route(async (req) => {
        const q = req.query;
        return dcFetch(`/api/characters/fresh?${new URLSearchParams({ summary: '1', sortBy: q.sortBy ?? 'score', limit24: q.limit24 ?? '80', limitWeek: q.limitWeek ?? '20' })}`, 48 * 1024 * 1024);
    }));
    router.get('/datacat/tags', route(async (req) => {
        const params = new URLSearchParams({ mode: 'recent', minTotalTokens: req.query.min_tokens ?? String(DATACAT_MIN_TOKENS) });
        const ids = splitIds(req.query.activeTagIds);
        if (ids.length) params.set('activeTagIds', ids.join(','));
        // the full catalog is about 28k tags, well past the usual JSON cap
        return dcFetch(`/api/tags/faceted?${params}`, 48 * 1024 * 1024);
    }));
    router.get('/datacat/character/:id', route(async (req) => dcFetch(`/api/characters/${encodeURIComponent(req.params.id)}`)));
    router.get('/datacat/download/:id', route(async (req) => dcFetch(`/api/characters/${encodeURIComponent(req.params.id)}/download?t=${Date.now()}`)));
    router.get('/datacat/avatar/*', route(async (req, res) => {
        const raw = req.params[0];
        if (!raw) throw new HttpError(400, 'Missing avatar path');
        const url = new URL(raw.startsWith('http') ? raw : `${DATACAT_IMAGES}${encodePath(raw)}`);
        if (!hostAllowed(url.hostname, ['ella.janitorai.com', 'media.datacat.run'])) throw new HttpError(400, 'Unsupported avatar host');
        return sendImage(res, await fetchImage(url, [url.hostname], { Referer: `${DATACAT_API}/` }));
    }));
}

export async function exit() {
    pygToken = '';
    dcToken = '';
}
