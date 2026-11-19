// Card Browser: search ChubAI, JannyAI, Pygmalion, Wyvern, DataCat and PlotLight, then import cards as characters or personas.
// A port of Marinara Engine's Card Browser (AGPL-3.0) to SillyTavern. Pygmalion, Wyvern and DataCat block browser
// requests, so they go through the companion "cardbrowser" server plugin; the other sources also work without it.

import { default_avatar, default_user_avatar, getRequestHeaders, processDroppedFiles } from '../../../../script.js';
import { power_user } from '../../../power-user.js';
import { tag_import_setting } from '../../../tags.js';
import { convertCharacterBook, saveWorldInfo, updateWorldInfoList } from '../../../world-info.js';
import { getUserAvatars, initPersona } from '../../../personas.js';

const PLUGIN = '/api/plugins/cardbrowser';
const STORAGE_KEY = 'cardbrowser-persist';
const JANNY_FALLBACK_TOKEN = '88a6463b66e04fb07ba87ee3db06af337f492ce511d93df6e2d2968cb2ff2b30';
const JANNY_DOWNLOAD_API = 'https://api.jannyai.com/api/v1/download';
const CHUB_API = 'https://api.chub.ai';
const CHUB_AVATARS = 'https://avatars.charhub.io';

let pluginAvailable = false;

// ════════════════════════════════════════════════
// Helpers
// ════════════════════════════════════════════════

const ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
const esc = (value) => String(value ?? '').replace(/[&<>"']/g, c => ESCAPES[c]);

function fmtNum(n) {
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
    if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
    return String(n);
}

function optionalString(value) {
    if (typeof value !== 'string') return undefined;
    const trimmed = value.trim();
    return trimmed ? trimmed : undefined;
}

function optionalStringArray(value) {
    if (!Array.isArray(value)) return undefined;
    const values = value.map(item => String(item).trim()).filter(Boolean);
    return values.length ? values : undefined;
}

function optionalRecord(value) {
    return value && typeof value === 'object' && !Array.isArray(value) ? value : undefined;
}

function stripHtml(value) {
    return String(value ?? '').replace(/<[^>]*>/g, '');
}

function encodeProxyPath(path) {
    return String(path ?? '').split('/').map(encodeURIComponent).join('/');
}

function readCardTags(value) {
    if (Array.isArray(value)) return value.map(String).map(t => t.trim()).filter(Boolean);
    if (typeof value === 'string') return value.split(',').map(t => t.trim()).filter(Boolean);
    return [];
}

function readCharacterCardData(raw) {
    if ((raw?.spec === 'chara_card_v2' || raw?.spec === 'chara_card_v3') && optionalRecord(raw.data)) return raw.data;
    return raw ?? {};
}

function countLorebookEntries(value) {
    const entries = optionalRecord(value)?.entries;
    if (Array.isArray(entries)) return entries.length;
    if (entries && typeof entries === 'object') return Object.keys(entries).length;
    return 0;
}

const hasLorebookEntries = value => countLorebookEntries(value) > 0;

function readCharacterCardDetailFields(raw) {
    const data = readCharacterCardData(raw);
    const strings = value => typeof value === 'string' && value.trim() ? value : undefined;
    const detail = {
        description: strings(data.description),
        personality: strings(data.personality),
        scenario: strings(data.scenario),
        firstMessage: strings(data.first_mes),
        exampleDialogs: strings(data.mes_example),
        alternateGreetings: Array.isArray(data.alternate_greetings) && data.alternate_greetings.some(g => typeof g === 'string')
            ? data.alternate_greetings.filter(g => typeof g === 'string') : undefined,
        creatorNotes: strings(data.creator_notes),
        systemPrompt: strings(data.system_prompt),
        postHistoryInstructions: strings(data.post_history_instructions),
        characterVersion: strings(data.character_version),
        hasLorebook: hasLorebookEntries(data.character_book),
        embeddedLorebook: data.character_book,
        extensions: optionalRecord(data.extensions),
    };
    return Object.values(detail).some(v => v !== undefined && v !== false) ? detail : null;
}

function hasJannyCharacterDefinition(detail) {
    return Boolean(detail?.description || detail?.personality || detail?.scenario || detail?.firstMessage
        || detail?.exampleDialogs || detail?.systemPrompt || detail?.postHistoryInstructions || detail?.alternateGreetings?.length);
}

function attachEmbeddedLorebook(raw, embeddedLorebook) {
    if (!hasLorebookEntries(embeddedLorebook)) return raw;
    const cloned = { ...raw };
    const isCard = (cloned.spec === 'chara_card_v2' || cloned.spec === 'chara_card_v3') && optionalRecord(cloned.data);
    const target = isCard ? { ...cloned.data } : cloned;
    if (!target.character_book) target.character_book = embeddedLorebook;
    if (isCard) cloned.data = target;
    return cloned;
}

function mergeChubDetail(raw, summary, detail) {
    if (!detail) return raw;
    const cloned = { ...raw };
    const isCard = (cloned.spec === 'chara_card_v2' || cloned.spec === 'chara_card_v3') && optionalRecord(cloned.data);
    const target = isCard ? { ...cloned.data } : cloned;
    if (isCard) cloned.data = target;
    const set = (field, value) => { if (value !== undefined && value.trim()) target[field] = value; };
    set('description', detail.description);
    set('personality', detail.personality);
    set('scenario', detail.scenario);
    set('first_mes', detail.firstMessage);
    set('mes_example', detail.exampleDialogs);
    set('creator_notes', detail.creatorNotes);
    set('system_prompt', detail.systemPrompt);
    set('post_history_instructions', detail.postHistoryInstructions);
    set('character_version', detail.characterVersion);
    const hasText = field => typeof target[field] === 'string' && target[field].trim().length > 0;
    if (!hasText('name') && summary.name?.trim()) target.name = summary.name;
    if (!hasText('creator') && summary.creator?.trim()) target.creator = summary.creator;
    const tags = (summary.tags ?? []).map(t => t.trim()).filter(Boolean);
    if (!(Array.isArray(target.tags) && target.tags.some(t => typeof t === 'string' && t.trim())) && tags.length) target.tags = tags;
    const greetings = (detail.alternateGreetings ?? []).map(t => t.trim()).filter(Boolean);
    if (greetings.length) target.alternate_greetings = greetings;
    if (detail.extensions) target.extensions = { ...(optionalRecord(target.extensions) ?? {}), ...detail.extensions };
    if (!target.character_book && hasLorebookEntries(detail.embeddedLorebook)) target.character_book = detail.embeddedLorebook;
    return cloned;
}

function loadPersist() {
    try {
        const raw = localStorage.getItem(STORAGE_KEY);
        if (raw) return { nsfw: {}, logins: {}, ...JSON.parse(raw) };
    } catch { /* ignore */ }
    return { nsfw: {}, logins: {} };
}

function savePersist(data) {
    try {
        localStorage.setItem(STORAGE_KEY, JSON.stringify(data));
    } catch { /* ignore */ }
}

const getPersistNsfw = sourceId => loadPersist().nsfw[sourceId] ?? false;
const getPersistLogin = sourceId => loadPersist().logins[sourceId] ?? false;
function setPersistNsfw(sourceId, value) {
    const data = loadPersist();
    data.nsfw[sourceId] = value;
    savePersist(data);
}
function setPersistLogin(sourceId, value) {
    const data = loadPersist();
    data.logins[sourceId] = value;
    savePersist(data);
}

function pluginFetch(path, init = {}) {
    return fetch(`${PLUGIN}${path}`, { ...init, headers: { ...getRequestHeaders(), ...(init.headers ?? {}) } });
}

async function readImageDataUrl(url) {
    if (!url) return undefined;
    try {
        const response = await fetch(url, { referrerPolicy: 'no-referrer' });
        if (!response.ok) return undefined;
        const blob = await response.blob();
        return await new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => resolve(reader.result);
            reader.onerror = () => reject(reader.error);
            reader.readAsDataURL(blob);
        });
    } catch {
        return undefined;
    }
}

class BrowserSourceError extends Error { }
class PygmalionSessionExpiredError extends Error { }

async function throwIfPygmalionSessionExpired(res) {
    const data = res.status === 401 ? await res.json().catch(() => null) : null;
    if (data?.sessionExpired) throw new PygmalionSessionExpiredError();
}

// ════════════════════════════════════════════════
// PNG character cards
// ════════════════════════════════════════════════

const PNG_SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10];
const CHARA_KEYWORDS = new Set(['ccv3', 'chara']);

function base64ToUtf8(text) {
    const raw = atob(text.trim());
    const bytes = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
    return new TextDecoder().decode(bytes);
}

function utf8ToBase64(text) {
    const bytes = new TextEncoder().encode(text);
    let binary = '';
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(binary);
}

function parseCharaText(text) {
    try {
        return JSON.parse(text);
    } catch {
        return JSON.parse(base64ToUtf8(text));
    }
}

async function inflateZlib(data) {
    const stream = new Blob([data]).stream().pipeThrough(new DecompressionStream('deflate'));
    return new Uint8Array(await new Response(stream).arrayBuffer());
}

function readUint32(bytes, offset) {
    return ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
}

/** Walks a PNG's chunks; the callback gets (type, data, start, end) for each, end being past the CRC. */
function forEachChunk(bytes, callback) {
    for (let i = 0; i < 8; i++) {
        if (bytes[i] !== PNG_SIGNATURE[i]) throw new Error('Not a valid PNG file');
    }
    let offset = 8;
    while (offset + 12 <= bytes.length) {
        const length = readUint32(bytes, offset);
        const end = offset + 12 + length;
        if (end > bytes.length) break;
        const type = String.fromCharCode(...bytes.subarray(offset + 4, offset + 8));
        callback(type, bytes.subarray(offset + 8, offset + 8 + length), offset, end);
        offset = end;
        if (type === 'IEND') break;
    }
}

/** Reads the card JSON from tEXt, zTXt or iTXt chunks, preferring V3 "ccv3" over V2 "chara". */
async function parsePngCharacterCard(blob) {
    const bytes = new Uint8Array(await blob.arrayBuffer());
    const pending = [];
    forEachChunk(bytes, (type, data) => {
        if (type !== 'tEXt' && type !== 'zTXt' && type !== 'iTXt') return;
        const nul = data.indexOf(0);
        if (nul <= 0) return;
        const keyword = new TextDecoder().decode(data.subarray(0, nul));
        if (!CHARA_KEYWORDS.has(keyword)) return;
        if (type === 'tEXt') pending.push([keyword, Promise.resolve(new TextDecoder().decode(data.subarray(nul + 1)))]);
        else if (type === 'zTXt' && data[nul + 1] === 0) {
            pending.push([keyword, inflateZlib(data.subarray(nul + 2)).then(b => new TextDecoder().decode(b))]);
        } else if (type === 'iTXt' && data[nul + 1] === 0) {
            const langEnd = data.indexOf(0, nul + 3);
            const transEnd = langEnd >= 0 ? data.indexOf(0, langEnd + 1) : -1;
            if (transEnd >= 0) pending.push([keyword, Promise.resolve(new TextDecoder().decode(data.subarray(transEnd + 1)))]);
        }
    });
    const found = new Map();
    for (const [keyword, textPromise] of pending) {
        if (found.has(keyword)) continue;
        try {
            found.set(keyword, parseCharaText(await textPromise));
        } catch { /* a malformed chunk; another may carry the card */ }
    }
    const json = found.get('ccv3') ?? found.get('chara');
    if (!json) throw new Error("No character data found in PNG, this doesn't appear to be a character card");
    return { json, bytes };
}

let crcTable = null;
function crc32(data) {
    if (!crcTable) {
        crcTable = new Uint32Array(256);
        for (let n = 0; n < 256; n++) {
            let c = n;
            for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
            crcTable[n] = c;
        }
    }
    let crc = 0xffffffff;
    for (let i = 0; i < data.length; i++) crc = crcTable[(crc ^ data[i]) & 0xff] ^ (crc >>> 8);
    return (crc ^ 0xffffffff) >>> 0;
}

function textChunk(keyword, text) {
    const payload = new TextEncoder().encode(`${keyword}\0${text}`);
    const chunk = new Uint8Array(12 + payload.length);
    const view = new DataView(chunk.buffer);
    view.setUint32(0, payload.length);
    chunk.set(new TextEncoder().encode('tEXt'), 4);
    chunk.set(payload, 8);
    view.setUint32(8 + payload.length, crc32(chunk.subarray(4, 8 + payload.length)));
    return chunk;
}

/** Returns the PNG with every existing card chunk replaced by the given card (V2 "chara", plus "ccv3" for V3 cards). */
function writeCardIntoPng(bytes, card) {
    const kept = [];
    let iend = null;
    forEachChunk(bytes, (type, data, start, end) => {
        if (type === 'IEND') {
            iend = bytes.subarray(start, end);
            return;
        }
        if (type === 'tEXt' || type === 'zTXt' || type === 'iTXt') {
            const nul = data.indexOf(0);
            if (nul > 0 && CHARA_KEYWORDS.has(new TextDecoder().decode(data.subarray(0, nul)))) return;
        }
        kept.push(bytes.subarray(start, end));
    });
    if (!iend) throw new Error('Could not find IEND chunk in PNG');
    const v2 = card.spec === 'chara_card_v3' ? { ...card, spec: 'chara_card_v2', spec_version: '2.0' } : card;
    const added = [textChunk('chara', utf8ToBase64(JSON.stringify(v2)))];
    if (card.spec === 'chara_card_v3') added.push(textChunk('ccv3', utf8ToBase64(JSON.stringify(card))));
    const parts = [bytes.subarray(0, 8), ...kept, ...added, iend];
    const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
    let offset = 0;
    for (const part of parts) {
        out.set(part, offset);
        offset += part.length;
    }
    return out;
}

/** Draws any image the browser can decode into a fresh PNG. */
async function imageToPngBytes(source) {
    let blob = source;
    if (typeof source === 'string') {
        const response = await fetch(source, { referrerPolicy: 'no-referrer' });
        if (!response.ok) throw new Error('Failed to load avatar image');
        blob = await response.blob();
    }
    const bitmap = await createImageBitmap(blob);
    const canvas = document.createElement('canvas');
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    canvas.getContext('2d').drawImage(bitmap, 0, 0);
    bitmap.close?.();
    const png = await new Promise((resolve, reject) => canvas.toBlob(b => (b ? resolve(b) : reject(new Error('Canvas toBlob failed'))), 'image/png'));
    return new Uint8Array(await png.arrayBuffer());
}

function toV2Card(charData) {
    return {
        spec: 'chara_card_v2',
        spec_version: '2.0',
        data: {
            name: charData.name || '',
            description: charData.description || '',
            personality: charData.personality || '',
            scenario: charData.scenario || '',
            first_mes: charData.first_mes || '',
            mes_example: charData.mes_example || '',
            creator_notes: charData.creator_notes || '',
            system_prompt: charData.system_prompt || '',
            post_history_instructions: charData.post_history_instructions || '',
            tags: charData.tags || [],
            creator: charData.creator || '',
            character_version: charData.character_version || '',
            alternate_greetings: charData.alternate_greetings || [],
            extensions: charData.extensions || {},
            ...(charData.character_book ? { character_book: charData.character_book } : {}),
        },
    };
}

/** A card JSON as a V2/V3 card, whether it arrived wrapped or as bare V1-style fields. */
function asCard(json) {
    if ((json?.spec === 'chara_card_v2' || json?.spec === 'chara_card_v3') && optionalRecord(json.data)) {
        return { ...json, data: { ...json.data } };
    }
    const data = { ...(json ?? {}) };
    const card = toV2Card(data);
    for (const [key, value] of Object.entries(data)) {
        if (!key.startsWith('_') && !(key in card.data)) card.data[key] = value;
    }
    return card;
}

function downloadBlob(blob, filename) {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
}

// ════════════════════════════════════════════════
// JannyAI tag map
// ════════════════════════════════════════════════

const JANNY_TAG_MAP = {
    1: 'Male', 2: 'Female', 3: 'Non-binary', 4: 'Celebrity', 5: 'OC', 6: 'Fictional', 7: 'Real', 8: 'Game', 9: 'Anime',
    10: 'Historical', 11: 'Royalty', 12: 'Detective', 13: 'Hero', 14: 'Villain', 15: 'Magical', 16: 'Non-human', 17: 'Monster',
    18: 'Monster Girl', 19: 'Alien', 20: 'Robot', 21: 'Politics', 22: 'Vampire', 23: 'Giant', 24: 'OpenAI', 25: 'Elf',
    26: 'Multiple', 27: 'VTuber', 28: 'Dominant', 29: 'Submissive', 30: 'Scenario', 31: 'Pokemon', 32: 'Assistant',
    34: 'Non-English', 36: 'Philosophy', 38: 'RPG', 39: 'Religion', 41: 'Books', 42: 'AnyPOV', 43: 'Angst', 44: 'Demi-Human',
    45: 'Enemies to Lovers', 46: 'Smut', 47: 'MLM', 48: 'WLW', 49: 'Action', 50: 'Romance', 51: 'Horror', 52: 'Slice of Life',
    53: 'Fantasy', 54: 'Drama', 55: 'Comedy', 56: 'Mystery', 57: 'Sci-Fi', 59: 'Yandere', 60: 'Furry', 61: 'Movies/TV',
};
const JANNY_TAG_REVERSE = Object.fromEntries(Object.entries(JANNY_TAG_MAP).map(([id, name]) => [name.toLowerCase(), Number(id)]));
const jannyTagNames = ids => (ids || []).map(id => JANNY_TAG_MAP[id] || `Tag ${id}`);
const jannyTagNamesToIds = names => names.map(n => JANNY_TAG_REVERSE[n.toLowerCase()]).filter(id => id !== undefined).map(String);

// ════════════════════════════════════════════════
// Provider: ChubAI
// ════════════════════════════════════════════════

const CHUB_SORT_PRESETS = [
    { value: 'popular_week', sort: 'download_count', days: 7, special_mode: '' },
    { value: 'popular_month', sort: 'download_count', days: 30, special_mode: '' },
    { value: 'popular_all', sort: 'download_count', days: 0, special_mode: '' },
    { value: 'rated_week', sort: 'star_count', days: 7, special_mode: '' },
    { value: 'rated_all', sort: 'star_count', days: 0, special_mode: '' },
    { value: 'newest', sort: 'id', days: 30, special_mode: '' },
    { value: 'updated', sort: 'last_activity_at', days: 0, special_mode: '' },
    { value: 'recent_hits', sort: 'default', days: 0, special_mode: 'newcomer' },
    { value: 'random', sort: 'random', days: 0, special_mode: '' },
];

/** Same parameters the plugin route builds, for when Chub is called straight from the browser. */
function chubDirectSearchUrl(params) {
    const nsfw = params.get('nsfw') ?? 'true';
    const out = new URLSearchParams({
        search: params.get('q') ?? '', first: '48', page: params.get('page') ?? '1', namespace: 'characters', nsfw, nsfl: nsfw,
        nsfw_only: 'false', chub: 'true', count: 'true', include_forks: 'true', venus: 'false', min_tokens: params.get('min_tokens') ?? '50',
    });
    const sort = params.get('sort');
    if (sort && sort !== 'default') out.set('sort', sort);
    for (const [from, to] of [['asc', 'asc'], ['max_days_ago', 'max_days_ago'], ['special_mode', 'special_mode'], ['max_tokens', 'max_tokens'],
        ['tags', 'topics'], ['excludeTags', 'excludetopics'], ['require_images', 'require_images'], ['require_lore', 'require_lore'],
        ['require_expressions', 'require_expressions'], ['require_alternate_greetings', 'require_alternate_greetings']]) {
        if (params.get(from)) out.set(to, params.get(from));
    }
    return `${CHUB_API}/search?${out}`;
}

const chubAvatarUrl = (fullPath, full = false) => pluginAvailable
    ? `${PLUGIN}/chub/avatar/${encodeProxyPath(fullPath)}${full ? '?full=1' : ''}`
    : `${CHUB_AVATARS}/avatars/${encodeProxyPath(fullPath)}/${full ? 'chara_card_v2.png' : 'avatar.webp'}`;

const chubProvider = {
    id: 'chub',
    name: 'ChubAI',
    icon: '✦',
    siteName: 'Chub',
    defaultSort: 'popular_all',
    pageSize: 48,
    sortOptions: [
        { value: 'popular_all', label: '👑 Most Downloaded', group: 'Popular' },
        { value: 'popular_week', label: '🔥 Hot This Week', group: 'Popular' },
        { value: 'popular_month', label: '📈 Hot This Month', group: 'Popular' },
        { value: 'rated_week', label: '⭐ Top Rated (Week)', group: 'Quality' },
        { value: 'rated_all', label: '⭐ Top Rated (All Time)', group: 'Quality' },
        { value: 'newest', label: '🆕 Newest', group: 'Discovery' },
        { value: 'updated', label: '🔄 Recently Updated', group: 'Discovery' },
        { value: 'recent_hits', label: '🌟 Recent Hits', group: 'Discovery' },
        { value: 'random', label: '🎲 Random', group: 'Discovery' },
    ],
    features: [
        { key: 'images', label: 'Image Gallery', icon: '🖼️' },
        { key: 'lore', label: 'Lorebook', icon: '📖' },
        { key: 'expressions', label: 'Expressions', icon: '😊' },
        { key: 'greetings', label: 'Alt Greetings', icon: '💬' },
    ],
    hasSortDirection: true,
    hasTokenFilters: true,
    extraToggles: [],
    nsfwAvailable: true,
    nsfwMode: 'free',
    async search(p) {
        const preset = CHUB_SORT_PRESETS.find(pr => pr.value === p.sort) ?? CHUB_SORT_PRESETS[0];
        const params = new URLSearchParams({ q: p.query, page: String(p.page), nsfw: String(p.nsfw) });
        if (p.query.trim()) {
            if (preset.sort !== 'default') params.set('sort', preset.sort);
        } else {
            params.set('sort', preset.sort);
            if (preset.days > 0) params.set('max_days_ago', String(preset.days));
            if (preset.special_mode) params.set('special_mode', preset.special_mode);
        }
        if (p.sortAsc) params.set('asc', 'true');
        if (p.includeTags.length) params.set('tags', p.includeTags.join(','));
        if (p.excludeTags.length) params.set('excludeTags', p.excludeTags.join(','));
        if (p.minTokens) params.set('min_tokens', p.minTokens);
        if (p.maxTokens) params.set('max_tokens', p.maxTokens);
        if (p.features.images) params.set('require_images', 'true');
        if (p.features.lore) params.set('require_lore', 'true');
        if (p.features.expressions) params.set('require_expressions', 'true');
        if (p.features.greetings) params.set('require_alternate_greetings', 'true');
        const res = pluginAvailable ? await pluginFetch(`/chub/search?${params}`) : await fetch(chubDirectSearchUrl(params), { referrerPolicy: 'no-referrer' });
        if (!res.ok) throw new Error('Search failed');
        const raw = await res.json();
        const data = raw?.data ?? raw;
        const nodes = data?.nodes ?? [];
        const hasMore = !!data?.cursor;
        const reported = typeof data?.count === 'number' ? data.count : Number(data?.count);
        const total = Number.isFinite(reported) && reported > 0 ? reported : hasMore ? (p.page + 1) * 48 : (p.page - 1) * 48 + nodes.length;
        return {
            cards: nodes.map(n => ({
                id: n.fullPath,
                name: n.name || 'Unnamed',
                creator: (n.fullPath || '').split('/')[0] || '',
                tagline: n.tagline || '',
                tags: n.topics || [],
                avatarUrl: chubAvatarUrl(n.fullPath),
                fullAvatarUrl: chubAvatarUrl(n.fullPath, true),
                stat1: n.starCount || 0, stat1Label: 'Downloads', stat1Icon: 'download',
                stat2: n.nChats || 0, stat2Label: 'Chats', stat2Icon: 'message',
                stat3: n.nTokens || 0, stat3Label: 'Tokens', stat3Icon: 'hash',
                // search rows can omit the boolean while still carrying the NSFW topic
                nsfw: n.nsfw === true || (n.nsfw == null && Array.isArray(n.topics) && n.topics.some(t => String(t).trim().toLowerCase() === 'nsfw')),
                externalUrl: `https://chub.ai/characters/${n.fullPath}`,
                _raw: n,
            })),
            totalCount: total,
        };
    },
    async fetchDetail(card) {
        const res = pluginAvailable
            ? await pluginFetch(`/chub/character/${card.id}`)
            : await fetch(`${CHUB_API}/api/characters/${encodeURI(card.id)}?full=true&nocache=${Date.now()}`, { referrerPolicy: 'no-referrer' });
        if (!res.ok) return null;
        const raw = await res.json();
        const node = raw?.data?.node ?? raw?.node;
        if (!node) return null;
        const def = node.definition || {};
        return {
            description: optionalString(def.personality),
            personality: optionalString(def.tavern_personality),
            scenario: optionalString(def.scenario),
            firstMessage: optionalString(def.first_message),
            exampleDialogs: optionalString(def.example_dialogs),
            alternateGreetings: optionalStringArray(def.alternate_greetings),
            creatorNotes: optionalString(def.description),
            systemPrompt: optionalString(def.system_prompt),
            postHistoryInstructions: optionalString(def.post_history_instructions),
            characterVersion: optionalString(def.character_version),
            hasLorebook: !!def.embedded_lorebook,
            embeddedLorebook: def.embedded_lorebook,
            extensions: optionalRecord(def.extensions),
        };
    },
    downloadUrl(card) {
        return pluginAvailable ? `${PLUGIN}/chub/download/${card.id}` : `${CHUB_AVATARS}/avatars/${encodeURI(card.id)}/chara_card_v2.png`;
    },
};

// ════════════════════════════════════════════════
// Provider: JannyAI
// ════════════════════════════════════════════════

/** The signed card URL comes from Janny itself; the browser tries first because Cloudflare often refuses servers. */
async function fetchCompleteJannyCard(characterId) {
    const signal = AbortSignal.timeout(45_000);
    try {
        const downloadResponse = await fetch(JANNY_DOWNLOAD_API, {
            method: 'POST',
            credentials: 'include',
            headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
            body: JSON.stringify({ characterId }),
            signal,
        });
        if (!downloadResponse.ok) throw new Error(`JannyAI character-card request failed (${downloadResponse.status})`);
        const payload = await downloadResponse.json();
        if (payload.status !== 'ok' || typeof payload.downloadUrl !== 'string') throw new Error('JannyAI did not return a character-card download');
        const downloadUrl = new URL(payload.downloadUrl);
        if (downloadUrl.protocol !== 'https:') throw new Error('JannyAI returned an insecure download URL');
        const cardResponse = await fetch(downloadUrl, { credentials: 'include', headers: { Accept: 'image/png,application/octet-stream;q=0.9' }, signal });
        if (!cardResponse.ok) throw new Error(`JannyAI character-card download failed (${cardResponse.status})`);
        return cardResponse;
    } catch (error) {
        if (!pluginAvailable) throw error;
        return pluginFetch(`/janny/download/${encodeURIComponent(characterId)}`, { signal });
    }
}

async function jannyToken(force = false) {
    if (!pluginAvailable) return JANNY_FALLBACK_TOKEN;
    const res = await pluginFetch(`/janny/token${force ? '?force=1' : ''}`);
    if (!res.ok) throw new Error('Could not obtain JannyAI token');
    const { token } = await res.json();
    if (!token) throw new Error('JannyAI token unavailable');
    return token;
}

function decodeAstro(value) {
    if (!Array.isArray(value)) return value;
    const [type, data] = value;
    if (type === 0 && data && typeof data === 'object' && !Array.isArray(data)) {
        return Object.fromEntries(Object.entries(data).map(([k, v]) => [k, decodeAstro(v)]));
    }
    if (type === 1 && Array.isArray(data)) return data.map(decodeAstro);
    return data;
}

function parseJannyCharacterHtml(html) {
    if (!html || html.includes('Just a moment') || html.includes('cf-challenge') || html.includes('challenge-platform')) return null;
    const doc = new DOMParser().parseFromString(html, 'text/html');
    const islands = [...doc.querySelectorAll('astro-island[props]')];
    const island = islands.find(el => el.getAttribute('component-export') === 'CharacterButtons')
        ?? islands.find(el => el.getAttribute('props').includes('character'));
    if (!island) return null;
    try {
        return decodeAstro(JSON.parse(island.getAttribute('props')).character) ?? null;
    } catch {
        return null;
    }
}

function jannyDetailFromCharacter(char) {
    if (!char) return null;
    const definition = optionalRecord(char.definition) ?? {};
    const pick = (...values) => values.find(v => typeof v === 'string' && v.trim().length > 0)?.trim();
    const description = pick(char.personality, char.description, char.definition_character_description, definition.description, definition.personality);
    const personality = pick(char.tavern_personality, char.definition_personality, char.definition, definition.tavern_personality, definition.personality);
    const scenario = pick(char.scenario, char.definition_scenario, definition.scenario);
    const firstMessage = pick(char.firstMessage, char.first_message, char.first_mes, char.definition_first_message,
        definition.firstMessage, definition.first_message, definition.first_mes);
    const exampleDialogs = pick(char.exampleDialogs, char.example_dialogs, char.mes_example, char.definition_example_messages,
        definition.exampleDialogs, definition.example_dialogs, definition.mes_example);
    const creatorNotes = pick(char.creatorNotes, char.creator_notes, char.creatorNote, char.description_html)?.replace(/<[^>]*>/g, '').trim();
    if (!(description || personality || scenario || firstMessage || exampleDialogs || creatorNotes)) return null;
    return {
        description,
        personality: personality && personality !== description ? personality : undefined,
        scenario,
        firstMessage,
        exampleDialogs,
        alternateGreetings: optionalStringArray(char.alternateGreetings ?? char.alternate_greetings ?? definition.alternateGreetings ?? definition.alternate_greetings),
        creatorNotes: creatorNotes && creatorNotes !== description ? creatorNotes : undefined,
        systemPrompt: optionalString(char.systemPrompt ?? char.system_prompt ?? definition.systemPrompt ?? definition.system_prompt),
        postHistoryInstructions: optionalString(char.postHistoryInstructions ?? char.post_history_instructions
            ?? definition.postHistoryInstructions ?? definition.post_history_instructions),
        characterVersion: optionalString(char.characterVersion ?? char.character_version ?? definition.characterVersion ?? definition.character_version),
    };
}

const jannyProvider = {
    id: 'janny',
    name: 'JannyAI',
    icon: '🤖',
    siteName: 'JannyAI',
    defaultSort: 'newest',
    pageSize: 80,
    sortOptions: [
        { value: 'newest', label: '🆕 Newest', group: 'Date' },
        { value: 'oldest', label: '🕐 Oldest', group: 'Date' },
        { value: 'tokens_desc', label: '📊 Most Tokens', group: 'Tokens' },
        { value: 'tokens_asc', label: '📊 Least Tokens', group: 'Tokens' },
        { value: 'relevant', label: '🔍 Relevance', group: 'Search' },
    ],
    features: [],
    hasSortDirection: false,
    hasTokenFilters: true,
    extraToggles: [{ key: 'showLowQuality', label: 'Show Low Quality', icon: '🚫' }],
    nsfwAvailable: true,
    nsfwMode: 'free',
    async search(p) {
        // The MeiliSearch POST runs from the browser: Cloudflare lets real browsers through where it blocks servers.
        let token = await jannyToken();
        const sortMap = { newest: ['createdAtStamp:desc'], oldest: ['createdAtStamp:asc'], tokens_desc: ['totalToken:desc'], tokens_asc: ['totalToken:asc'], relevant: [] };
        const sortArr = sortMap[p.sort] ?? sortMap.newest;
        // Known tags filter upstream by id, free-form ones client-side against the resolved names.
        const knownIncludeTagIds = jannyTagNamesToIds(p.includeTags);
        const customIncludeTags = p.includeTags.filter(t => JANNY_TAG_REVERSE[t.toLowerCase()] === undefined).map(t => t.toLowerCase());
        const fetchOnePage = async (pageNum) => {
            const filters = [`totalToken >= ${parseInt(p.minTokens) || 29}`, `totalToken <= ${parseInt(p.maxTokens) || 100000}`];
            if (!p.nsfw) filters.push('isNsfw = false');
            if (!p.extraToggles.showLowQuality) filters.push('isLowQuality = false');
            if (knownIncludeTagIds.length) filters.push(knownIncludeTagIds.map(id => `tagIds = ${id}`).join(' AND '));
            const body = {
                queries: [{
                    indexUid: 'janny-characters', q: p.query, facets: ['isLowQuality', 'isNsfw', 'tagIds', 'totalToken'],
                    attributesToCrop: ['description:300'], cropMarker: '...', filter: filters, attributesToHighlight: ['name', 'description'],
                    highlightPreTag: '__ais-highlight__', highlightPostTag: '__/ais-highlight__', hitsPerPage: 80, page: pageNum,
                    ...(sortArr.length ? { sort: sortArr } : {}),
                }],
            };
            // No credentials: the endpoint answers with a wildcard origin, which browsers refuse to pair with cookies.
            const doFetch = authToken => fetch('https://search.jannyai.com/multi-search', {
                method: 'POST',
                referrerPolicy: 'no-referrer',
                headers: {
                    Accept: '*/*', 'Content-Type': 'application/json', Authorization: `Bearer ${authToken}`,
                    'x-meilisearch-client': 'Meilisearch instant-meilisearch (v0.19.0) ; Meilisearch JavaScript (v0.41.0)',
                },
                body: JSON.stringify(body),
            });
            let res = await doFetch(token);
            if (res.status === 401 || res.status === 403) {
                try {
                    token = await jannyToken(true);
                    res = await doFetch(token);
                } catch { /* reported below */ }
            }
            if (!res.ok) {
                if (res.status === 403) throw new Error('JannyAI is blocking the request (Cloudflare). Visit https://jannyai.com once in this browser to clear the challenge, then retry.');
                throw new Error(`JannyAI search error ${res.status}`);
            }
            return (await res.json())?.results?.[0];
        };
        const lowerExclude = p.excludeTags.map(t => t.toLowerCase());
        const applyClientFilter = hits => (lowerExclude.length === 0 && customIncludeTags.length === 0) ? hits : hits.filter(h => {
            const names = jannyTagNames(h.tagIds || []).map(t => t.toLowerCase());
            if (lowerExclude.some(t => names.includes(t))) return false;
            return customIncludeTags.every(t => names.includes(t));
        });
        let currentPage = p.page;
        const result = await fetchOnePage(currentPage);
        let hits = applyClientFilter(result?.hits || []);
        const totalPages = result?.totalPages || 1;
        if (lowerExclude.length || customIncludeTags.length) {
            for (let extra = 0; hits.length < 80 && currentPage < totalPages && extra < 3; extra++) {
                currentPage++;
                hits = hits.concat(applyClientFilter((await fetchOnePage(currentPage))?.hits || []));
            }
        }
        return {
            cards: hits.map(h => ({
                id: h.id || '',
                name: h.name || 'Unnamed',
                creator: h.creatorUsername || '',
                tagline: stripHtml(h.description).slice(0, 200),
                tags: jannyTagNames(h.tagIds),
                avatarUrl: h.avatar ? (pluginAvailable ? `${PLUGIN}/janny/avatar/${encodeProxyPath(h.avatar)}` : `https://image.jannyai.com/bot-avatars/${encodeProxyPath(h.avatar)}`) : '',
                stat1: h.totalToken || 0, stat1Label: 'Tokens', stat1Icon: 'hash',
                stat2: 0, stat2Label: '', stat2Icon: 'star',
                stat3: 0, stat3Label: '', stat3Icon: 'star',
                nsfw: !!h.isNsfw,
                externalUrl: `https://jannyai.com/characters/${h.id}_character-${(h.name || '').toLowerCase().replace(/[^a-z0-9]+/g, '-')}`,
                _raw: h,
            })),
            totalCount: result?.totalHits ?? totalPages * 80,
        };
    },
    async fetchDetail(card, options) {
        const raw = card._raw;
        const charId = raw?.id || card.id;
        const slug = card.name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
        if (!options?.skipCompleteCard) {
            try {
                const cardRes = await fetchCompleteJannyCard(charId);
                if (cardRes.ok) {
                    const { json } = await parsePngCharacterCard(await cardRes.blob());
                    const detail = readCharacterCardDetailFields(json);
                    if (hasJannyCharacterDefinition(detail)) return detail;
                }
            } catch { /* fall through to the page */ }
        }
        // Janny's API mirror serves the same Astro page with permissive CORS.
        try {
            const res = await fetch(`https://api.jannyai.com/characters/${charId}_character-${slug}`, { headers: { Accept: 'text/html,application/xhtml+xml,*/*' }, referrerPolicy: 'no-referrer' });
            if (res.ok) {
                const detail = jannyDetailFromCharacter(parseJannyCharacterHtml(await res.text()));
                if (detail) return detail;
            }
        } catch { /* fall through */ }
        if (pluginAvailable) {
            try {
                const res = await pluginFetch(`/janny/character/${encodeURIComponent(charId)}?slug=character-${slug}`);
                if (res.ok) {
                    const detail = jannyDetailFromCharacter((await res.json())?.character);
                    if (detail) return detail;
                }
            } catch { /* fall through */ }
        }
        const plainDesc = stripHtml(raw?.description).trim();
        return plainDesc ? { creatorNotes: plainDesc } : null;
    },
};

// ════════════════════════════════════════════════
// Provider: CharacterTavern (unavailable)
// ════════════════════════════════════════════════

const chartavernProvider = {
    id: 'chartavern',
    name: 'CharacterTavern',
    icon: '🍺',
    siteName: 'CharacterTavern',
    unavailable: {
        notice: 'CharacterTavern rebuilt its website and no longer offers the connection Marinara used to search and download cards. Browsing may return if CharacterTavern offers API access. Until then, you can download cards from character-tavern.com and import the file.',
        siteUrl: 'https://character-tavern.com',
    },
    defaultSort: '',
    pageSize: 1,
    sortOptions: [],
    features: [],
    hasSortDirection: false,
    hasTokenFilters: false,
    extraToggles: [],
    nsfwAvailable: false,
    nsfwMode: 'free',
    search: async () => ({ cards: [], totalCount: 0 }),
    fetchDetail: async () => null,
};

// ════════════════════════════════════════════════
// Provider: Pygmalion
// ════════════════════════════════════════════════

const PYGMALION_LOGIN_FAILURES = {
    invalid: "Paste only the token. It can't contain spaces or line breaks.",
    rejected: 'Pygmalion rejected the token.',
    unreachable: "Couldn't reach Pygmalion. Try again later.",
    busy: 'Pygmalion is busy. Try again in a moment.',
};

const pygmalionProvider = {
    id: 'pygmalion',
    name: 'Pygmalion',
    icon: '🔥',
    siteName: 'Pygmalion',
    needsPlugin: true,
    defaultSort: 'downloads',
    pageSize: 48,
    sortOptions: [
        { value: 'downloads', label: '⬇️ Downloads' },
        { value: 'stars', label: '⭐ Stars' },
        { value: 'views', label: '👁️ Views' },
        { value: 'approved_at', label: '🆕 Newest' },
        { value: 'token_count', label: '📝 Tokens' },
        { value: 'display_name', label: '🔤 Name' },
    ],
    features: [],
    hasSortDirection: true,
    hasTokenFilters: false,
    extraToggles: [],
    nsfwAvailable: false,
    nsfwMode: 'login',
    async search(p) {
        const params = new URLSearchParams({ q: p.query, page: String(Math.max(0, p.page - 1)), pageSize: '48', orderBy: p.sort, orderDescending: String(!p.sortAsc) });
        if (p.includeTags.length) params.set('tagsInclude', p.includeTags.join(','));
        if (p.excludeTags.length) params.set('tagsExclude', p.excludeTags.join(','));
        if (p.nsfw) params.set('includeSensitive', 'true');
        const res = await pluginFetch(`/pygmalion/search?${params}`);
        if (!res.ok) {
            await throwIfPygmalionSessionExpired(res);
            throw new Error('Search failed');
        }
        const data = await res.json();
        return {
            cards: (data?.characters || []).map(c => {
                const owner = c.owner || {};
                const av = c.avatarUrl;
                return {
                    id: c.id || '',
                    name: c.displayName || 'Unnamed',
                    creator: owner.username || owner.displayName || '',
                    tagline: c.description || '',
                    tags: Array.isArray(c.tags) ? c.tags : [],
                    avatarUrl: av ? `${PLUGIN}/pygmalion/avatar/${av.startsWith('http') ? encodeURIComponent(av) : encodeProxyPath(av)}` : '',
                    stat1: c.downloads || 0, stat1Label: 'Downloads', stat1Icon: 'download',
                    stat2: c.stars || 0, stat2Label: 'Stars', stat2Icon: 'star',
                    stat3: c.chatCount || 0, stat3Label: 'Chats', stat3Icon: 'message',
                    nsfw: !!c.isSensitive,
                    externalUrl: `https://pygmalion.chat/character/${c.id}`,
                    _raw: c,
                };
            }),
            totalCount: parseInt(data?.totalItems || '0', 10),
        };
    },
    async fetchDetail(card) {
        const res = await pluginFetch(`/pygmalion/character?id=${encodeURIComponent(card.id)}`);
        if (!res.ok) {
            await throwIfPygmalionSessionExpired(res);
            return null;
        }
        const char = (await res.json())?.character;
        if (!char) return null;
        const p = char.personality || {};
        return {
            description: p.persona || undefined,
            firstMessage: p.greeting || undefined,
            exampleDialogs: p.mesExample || undefined,
            creatorNotes: p.characterNotes || undefined,
            systemPrompt: optionalString(p.systemPrompt ?? p.system_prompt ?? char.systemPrompt ?? char.system_prompt),
            postHistoryInstructions: optionalString(p.postHistoryInstructions ?? p.post_history_instructions ?? char.postHistoryInstructions ?? char.post_history_instructions),
            characterVersion: optionalString(p.characterVersion ?? p.character_version ?? char.characterVersion ?? char.character_version),
            alternateGreetings: Array.isArray(p.alternateGreetings) ? p.alternateGreetings.filter(Boolean) : [],
        };
    },
};

// ════════════════════════════════════════════════
// Provider: Wyvern
// ════════════════════════════════════════════════

const wyvernProvider = {
    id: 'wyvern',
    name: 'Wyvern',
    icon: '🐉',
    siteName: 'Wyvern',
    needsPlugin: true,
    defaultSort: 'popular',
    pageSize: 48,
    sortOptions: [
        { value: 'popular', label: '🔥 Popular' },
        { value: 'nsfw-popular', label: '🔞 Popular NSFW' },
        { value: 'recommended', label: '⭐ Recommended' },
        { value: 'created_at', label: '🆕 New' },
        { value: 'votes', label: '❤️ Most Likes' },
        { value: 'messages', label: '💬 Most Messages' },
    ],
    features: [
        { key: 'lore', label: 'Lorebook', icon: '📖' },
        { key: 'greetings', label: 'Alt Greetings', icon: '💬' },
    ],
    hasSortDirection: false,
    hasTokenFilters: true,
    extraToggles: [],
    nsfwAvailable: false,
    nsfwMode: 'wyvern',
    async search(p) {
        const params = new URLSearchParams({ page: String(p.page), limit: '48', sort: p.sort });
        if (p.query) params.set('q', p.query);
        if (p.includeTags.length) params.set('tags', p.includeTags.join(','));
        if (!p.nsfw && p.sort !== 'nsfw-popular') params.set('rating', 'none');
        const res = await pluginFetch(`/wyvern/search?${params}`);
        if (!res.ok) throw new Error('Search failed');
        const data = await res.json();
        let results = data?.results || [];
        if (p.excludeTags.length) {
            const lowerExclude = p.excludeTags.map(t => t.toLowerCase());
            results = results.filter(c => !lowerExclude.some(t => (c.tags || []).map(x => String(x).toLowerCase()).includes(t)));
        }
        return {
            cards: results.map(c => {
                const sr = c.statistics_record || c.entity_statistics || {};
                const src = c.avatar_url || c.avatar;
                return {
                    id: c.id || '',
                    name: c.name || 'Unnamed',
                    creator: c.creator?.displayName || c.creator?.username || '',
                    tagline: c.tagline || '',
                    tags: Array.isArray(c.tags) ? c.tags : [],
                    avatarUrl: src ? `${PLUGIN}/wyvern/avatar/${src.startsWith('http') ? encodeURIComponent(src) : `${encodeProxyPath(src)}/public`}` : '',
                    stat1: sr.likes || sr.total_likes || c.likes || 0, stat1Label: 'Likes', stat1Icon: 'heart',
                    stat2: sr.messages || sr.total_messages || c.messages || 0, stat2Label: 'Messages', stat2Icon: 'message',
                    stat3: sr.views || sr.total_views || c.views || 0, stat3Label: 'Views', stat3Icon: 'eye',
                    nsfw: !!(c.rating && c.rating !== 'none'),
                    externalUrl: `https://app.wyvern.chat/characters/${c.id}`,
                    _raw: c,
                };
            }),
            totalCount: data?.total ?? (data?.hasMore ? (p.page + 1) * 48 : results.length),
        };
    },
    async fetchDetail(card) {
        const res = await pluginFetch(`/wyvern/character/${encodeURIComponent(card.id)}`);
        if (!res.ok) return null;
        const c = await res.json();
        if (!c) return null;
        const embeddedLorebook = c.embedded_lorebook ?? c.character_book;
        return {
            description: c.description || undefined,
            personality: c.personality || undefined,
            scenario: c.scenario || undefined,
            firstMessage: c.first_mes || undefined,
            exampleDialogs: c.mes_example || undefined,
            creatorNotes: c.creator_notes || undefined,
            systemPrompt: optionalString(c.systemPrompt ?? c.system_prompt),
            postHistoryInstructions: optionalString(c.postHistoryInstructions ?? c.post_history_instructions),
            characterVersion: optionalString(c.characterVersion ?? c.character_version),
            alternateGreetings: Array.isArray(c.alternate_greetings) ? c.alternate_greetings.filter(Boolean) : [],
            hasLorebook: hasLorebookEntries(embeddedLorebook) || !!(c.lorebooks?.length > 0),
            embeddedLorebook,
        };
    },
};

// ════════════════════════════════════════════════
// Provider: DataCat (JanitorAI characters via datacat.run)
// ════════════════════════════════════════════════

// About 28k tags exist; the panel lists only the most popular, the maps still resolve the rest.
const TOP_TAGS_DISPLAY_LIMIT = 150;
const datacatTagNameToId = new Map();
const datacatTagIdToName = new Map();
let datacatTopTagNames = [];
let datacatTagsLoaded = false;
let datacatTagsLoading = null;

async function loadDatacatTags() {
    if (datacatTagsLoaded) return;
    if (datacatTagsLoading) return datacatTagsLoading;
    datacatTagsLoading = (async () => {
        try {
            const res = await pluginFetch('/datacat/tags');
            if (!res.ok) return;
            const data = await res.json();
            const list = data?.tags || data?.facets || data || [];
            const sortable = [];
            for (const t of Array.isArray(list) ? list : []) {
                const id = Number(t?.id ?? t?.tag_id ?? t?.tagId);
                const name = String(t?.name || t?.slug || '');
                if (Number.isFinite(id) && name) {
                    datacatTagNameToId.set(name.toLowerCase(), id);
                    datacatTagIdToName.set(id, name);
                    sortable.push({ name, count: Number(t?.count ?? 0) || 0 });
                }
            }
            sortable.sort((a, b) => b.count - a.count);
            datacatTopTagNames = sortable.slice(0, TOP_TAGS_DISPLAY_LIMIT).map(t => t.name);
            datacatTagsLoaded = true;
        } finally {
            datacatTagsLoading = null;
        }
    })();
    return datacatTagsLoading;
}

const datacatProvider = {
    id: 'datacat',
    name: 'DataCat',
    icon: '🐱',
    siteName: 'DataCat',
    needsPlugin: true,
    defaultSort: 'relevance',
    pageSize: 80,
    sortOptions: [
        { value: 'relevance', label: '🔍 Relevance' },
        { value: 'fresh', label: '🔥 Fresh' },
    ],
    features: [],
    hasSortDirection: false,
    hasTokenFilters: false,
    extraToggles: [],
    nsfwAvailable: false,
    nsfwMode: 'wyvern',
    async search(p) {
        await loadDatacatTags();
        const tagIds = p.includeTags.map(n => datacatTagNameToId.get(n.toLowerCase())).filter(id => typeof id === 'number');
        const query = p.query.trim();
        // "Fresh" is the 24h trending window, which has no text search or tag filter.
        const useFresh = p.sort === 'fresh' && tagIds.length === 0 && !query;
        let list = [];
        let totalCount = 0;
        if (useFresh) {
            const res = await pluginFetch(`/datacat/fresh?${new URLSearchParams({ sortBy: 'score', limit24: '80', limitWeek: '0' })}`);
            if (!res.ok) throw new Error('Search failed');
            const data = await res.json();
            const last24h = data?.windows?.last24h || data?.last24h;
            list = Array.isArray(last24h) ? last24h : last24h?.characters || [];
            // the window ignores paging, so its own count would advertise pages that replay it
            totalCount = list.length;
        } else {
            const params = new URLSearchParams({ limit: '80', offset: String(Math.max(0, (p.page - 1) * 80)) });
            if (tagIds.length) params.set('tagIds', tagIds.join(','));
            if (query) params.set('q', query);
            const res = await pluginFetch(`/datacat/recent?${params}`);
            if (!res.ok) throw new Error('Search failed');
            const data = await res.json();
            list = data?.characters || [];
            totalCount = data?.totalCount || list.length;
        }
        const tagName = t => typeof t === 'string' ? t : typeof t === 'number' ? datacatTagIdToName.get(t) || ''
            : t?.name || t?.slug || (typeof t?.id === 'number' ? datacatTagIdToName.get(t.id) || '' : '');
        if (p.excludeTags.length) {
            const lowerExclude = p.excludeTags.map(t => t.toLowerCase());
            list = list.filter(c => !lowerExclude.some(t => (Array.isArray(c.tags) ? c.tags : []).map(tagName).map(s => s.toLowerCase()).includes(t)));
        }
        return {
            cards: list.map(c => {
                const rawTags = Array.isArray(c.tags) ? c.tags : Array.isArray(c.tagIds) ? c.tagIds : [];
                const av = c.avatar || '';
                const charId = c.characterId || c.character_id || c.id || '';
                return {
                    id: charId,
                    name: c.chatName || c.chat_name || c.name || 'Unnamed',
                    creator: c.creatorName || c.creator_name || '',
                    tagline: stripHtml(c.description).slice(0, 200),
                    tags: rawTags.map(tagName).filter(Boolean),
                    avatarUrl: av ? `${PLUGIN}/datacat/avatar/${av.startsWith('http') ? encodeURIComponent(av) : encodeProxyPath(av)}` : '',
                    stat1: c.chatCount || c.chat_count || 0, stat1Label: 'Chats', stat1Icon: 'message',
                    stat2: c.totalTokens || c.total_tokens || 0, stat2Label: 'Tokens', stat2Icon: 'hash',
                    stat3: 0, stat3Label: '', stat3Icon: 'star',
                    nsfw: !!c.isNsfw,
                    externalUrl: `https://datacat.run/characters/${charId}`,
                    _raw: c,
                };
            }),
            totalCount,
        };
    },
    async fetchDetail(card) {
        const id = card._raw?.characterId || card._raw?.character_id || card.id;
        if (!id) return null;
        try {
            const dlRes = await pluginFetch(`/datacat/download/${encodeURIComponent(id)}`);
            if (dlRes.ok) {
                const d = (await dlRes.json())?.data;
                if (d) {
                    return {
                        description: d.description || d.personality || undefined,
                        personality: d.personality || undefined,
                        scenario: d.scenario || undefined,
                        firstMessage: d.first_mes || undefined,
                        exampleDialogs: d.mes_example || undefined,
                        creatorNotes: d.creator_notes || undefined,
                        systemPrompt: optionalString(d.systemPrompt ?? d.system_prompt),
                        postHistoryInstructions: optionalString(d.postHistoryInstructions ?? d.post_history_instructions),
                        characterVersion: optionalString(d.characterVersion ?? d.character_version),
                        alternateGreetings: Array.isArray(d.alternate_greetings) ? d.alternate_greetings.filter(Boolean) : [],
                    };
                }
            }
        } catch { /* fall through */ }
        try {
            const res = await pluginFetch(`/datacat/character/${encodeURIComponent(id)}`);
            if (!res.ok) return null;
            const data = await res.json();
            const c = data?.character || data;
            if (!c) return null;
            const plainDesc = stripHtml(c.description).trim();
            return {
                description: c.personality || undefined,
                scenario: c.scenario || undefined,
                firstMessage: c.first_message || undefined,
                creatorNotes: plainDesc || undefined,
                systemPrompt: optionalString(c.systemPrompt ?? c.system_prompt),
                postHistoryInstructions: optionalString(c.postHistoryInstructions ?? c.post_history_instructions),
                characterVersion: optionalString(c.characterVersion ?? c.character_version),
            };
        } catch {
            return null;
        }
    },
};

// ════════════════════════════════════════════════
// Provider: PlotLight (characters and personas, a CORS-enabled public API)
// ════════════════════════════════════════════════

class PlotLightError extends Error {
    constructor(status, retryAfterSeconds = null) {
        super(`PlotLight request failed (${status})`);
        this.status = status;
        this.retryAfterSeconds = retryAfterSeconds;
    }
}

const PLOTLIGHT_ORIGIN = 'https://plotlightstudios.com';
const PLOTLIGHT_PAGE_SIZE = 48;
const PLOTLIGHT_FORMATS = ['png3', 'png', 'json3', 'json'];
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;

function createPlotLightClient() {
    const base = new URL(PLOTLIGHT_ORIGIN);
    const tagCatalogs = new Map();
    const pageOffsets = new Map();
    let cursorKey = '';
    const blockedUntil = { search: 0, export: 0 };
    const text = value => typeof value === 'string' ? value.trim() : '';
    const record = value => optionalRecord(value) ?? {};
    const plotLightUrl = (value) => {
        const raw = text(value);
        if (!raw) return '';
        try {
            const url = new URL(raw, base);
            return url.origin === base.origin ? url.href : '';
        } catch {
            return '';
        }
    };
    const httpsUrl = (value) => {
        try {
            const url = new URL(text(value));
            return url.protocol === 'https:' ? url.href : '';
        } catch {
            return '';
        }
    };
    const nextOffsetOf = (body, offset) => {
        const next = record(body.pagination).next_offset;
        return Number.isInteger(next) && next > offset && next <= 10_000 ? next : null;
    };
    const mapItem = (raw) => {
        const item = record(raw);
        const id = text(item.id);
        const name = text(item.name);
        if (!UUID_PATTERN.test(id) || !name) return null;
        const links = record(item.downloads);
        const downloads = {};
        for (const format of PLOTLIGHT_FORMATS) {
            const url = plotLightUrl(links[format]);
            if (url) downloads[format] = url;
        }
        return {
            id, name,
            description: text(item.description),
            imageUrl: httpsUrl(item.image_url),
            creator: text(record(item.creator).name) || text(record(item.creator).username),
            tags: (Array.isArray(item.tags) ? item.tags : []).flatMap(tag => text(record(tag).name) && text(record(tag).slug) ? [{ name: text(record(tag).name), slug: text(record(tag).slug) }] : []),
            detailUrl: plotLightUrl(item.detail_url) || base.origin,
            downloads,
            adult: false,
        };
    };
    async function request(url, accept, timeoutMs, limit) {
        const waitMs = blockedUntil[limit] - Date.now();
        if (waitMs > 0) throw new PlotLightError(429, Math.ceil(waitMs / 1000));
        const response = await fetch(url, { credentials: 'omit', headers: { Accept: accept }, signal: AbortSignal.timeout(timeoutMs), referrerPolicy: 'no-referrer' });
        if (response.status === 429) {
            const header = response.headers.get('Retry-After')?.trim() ?? '';
            let seconds = /^\d+$/u.test(header) ? Number(header) : Math.ceil((Date.parse(header) - Date.now()) / 1000);
            seconds = Number.isFinite(seconds) && seconds > 0 ? Math.min(seconds, 600) : 30;
            blockedUntil[limit] = Date.now() + seconds * 1000;
            throw new PlotLightError(429, seconds);
        }
        const reset = Number(response.headers.get('X-RateLimit-Reset'));
        if (response.headers.get('X-RateLimit-Remaining')?.trim() === '0' && reset > 0) {
            blockedUntil[limit] = Math.min(reset * 1000, Date.now() + 600_000);
        }
        if (!response.ok) throw new PlotLightError(response.status);
        return response;
    }
    const searchJson = async url => record(await (await request(url, 'application/json', 30_000, 'search')).json());
    async function loadTagCatalog(type) {
        const catalog = { slugs: new Map(), adult: new Set() };
        for (let start = 0, more = true; more && start <= 10_000; start += 400) {
            const offsets = [0, 1, 2, 3].map(i => start + i * 100).filter(o => o <= 10_000);
            const pages = await Promise.all(offsets.map(offset => {
                const url = new URL('/api/v1/content/tags', base);
                url.searchParams.set('type', type);
                url.searchParams.set('include_after_dark', 'true');
                url.searchParams.set('limit', '100');
                url.searchParams.set('offset', String(offset));
                return searchJson(url);
            }));
            for (const body of pages) {
                for (const raw of Array.isArray(body.data) ? body.data : []) {
                    const tag = record(raw);
                    const slug = text(tag.slug);
                    if (!slug || slug.length > 50) continue;
                    for (const key of [text(tag.name).toLowerCase(), slug.toLowerCase()]) {
                        const slugs = catalog.slugs.get(key) ?? [];
                        if (key && !slugs.includes(slug)) catalog.slugs.set(key, [...slugs, slug]);
                    }
                    if (tag.requires_after_dark === true || tag.rating === 'after_dark') catalog.adult.add(slug);
                }
            }
            more = pages.every((body, i) => nextOffsetOf(body, offsets[i]) !== null);
        }
        return catalog;
    }
    function tagCatalog(type) {
        let catalog = tagCatalogs.get(type);
        if (!catalog) {
            catalog = loadTagCatalog(type);
            tagCatalogs.set(type, catalog);
            catalog.catch(() => tagCatalogs.delete(type));
        }
        return catalog;
    }
    const tagFilter = (names, slugs, include) => names.flatMap((name) => {
        const known = slugs.get(name.trim().toLowerCase());
        return known ? (include ? known.slice(0, 1) : known) : [name.trim()];
    }).filter(slug => slug && slug.length <= 50).slice(0, 10).join(',');
    async function fetchPage(search, offset, tags, excludeTags) {
        const url = new URL(`/api/v1/content/${search.type}`, base);
        const query = search.query.trim().slice(0, 200);
        if (query) url.searchParams.set('q', query);
        if (tags) url.searchParams.set('tags', tags);
        if (excludeTags) url.searchParams.set('exclude_tags', excludeTags);
        url.searchParams.set('sort', search.sort);
        url.searchParams.set('limit', String(PLOTLIGHT_PAGE_SIZE));
        url.searchParams.set('offset', String(offset));
        const body = await searchJson(url);
        return { items: (Array.isArray(body.data) ? body.data : []).map(mapItem).filter(Boolean), nextOffset: nextOffsetOf(body, offset) };
    }
    async function searchPage(search, page) {
        const key = JSON.stringify([search.type, search.query.trim(), search.sort, search.includeTags, search.excludeTags]);
        if (key !== cursorKey) {
            cursorKey = key;
            pageOffsets.clear();
        }
        const offset = page <= 1 ? 0 : (pageOffsets.get(page) ?? (page - 1) * PLOTLIGHT_PAGE_SIZE);
        const catalog = tagCatalog(search.type);
        const slugs = search.includeTags.length || search.excludeTags.length ? (await catalog).slugs : new Map();
        const tags = tagFilter(search.includeTags, slugs, true);
        const excludeTags = tagFilter(search.excludeTags, slugs, false);
        let result = await fetchPage(search, offset, tags, excludeTags);
        // discovery can drop items after paging, so an empty page is not necessarily the end
        for (let skips = 0; result.items.length === 0 && result.nextOffset !== null && skips < 2; skips++) {
            result = await fetchPage(search, result.nextOffset, tags, excludeTags);
        }
        const { adult } = await catalog;
        for (const item of result.items) item.adult = item.tags.some(tag => adult.has(tag.slug));
        if (key === cursorKey && result.nextOffset !== null) pageOffsets.set(page + 1, result.nextOffset);
        return { items: result.items, hasMore: result.nextOffset !== null };
    }
    async function downloadCard(item, formats) {
        let lastError = new PlotLightError(404);
        for (const format of formats) {
            const url = item.downloads[format];
            if (!url) continue;
            let response;
            try {
                response = await request(new URL(url), format.startsWith('png') ? 'image/png' : 'application/json', 60_000, 'export');
            } catch (error) {
                if (!(error instanceof PlotLightError) || (error.status !== 400 && error.status !== 404)) throw error;
                lastError = error;
                continue;
            }
            const card = format.startsWith('png')
                ? await parsePngCharacterCard(await response.blob())
                : { json: record(await response.json()), bytes: undefined };
            const data = readCharacterCardData(card.json);
            if (!text(data.name) && !text(data.description)) throw new Error('PlotLight sent an empty card');
            if (!text(data.creator) && item.creator) data.creator = item.creator;
            if (!(Array.isArray(data.tags) && data.tags.length) && item.tags.length) data.tags = item.tags.map(tag => tag.name);
            return card;
        }
        throw lastError;
    }
    return { searchPage, downloadCard };
}

const plotlightClient = createPlotLightClient();

function plotlightUserError(error, isDownload = true) {
    if (error instanceof PlotLightError && error.status === 429) {
        const n = error.retryAfterSeconds ?? 30;
        return new BrowserSourceError(`PlotLight is busy. Try again in ${n} second${n === 1 ? '' : 's'}.`);
    }
    if (isDownload && error instanceof PlotLightError && [401, 403, 404].includes(error.status)) {
        return new BrowserSourceError("PlotLight doesn't offer this for download.");
    }
    return new BrowserSourceError("Couldn't load from PlotLight. Try again later.");
}

function createPlotlightProvider(type) {
    const isPersona = type === 'personas';
    const detailFormats = isPersona ? ['json'] : ['json3', 'json'];
    const importFormats = isPersona ? ['json'] : ['png3', 'json3', 'json'];
    return {
        id: isPersona ? 'plotlight-personas' : 'plotlight',
        name: isPersona ? 'PlotLight Personas' : 'PlotLight',
        icon: isPersona ? '🎭' : '🔦',
        siteName: 'PlotLight',
        defaultSort: 'popular',
        pageSize: PLOTLIGHT_PAGE_SIZE,
        sortOptions: [
            { value: 'popular', label: '🔥 Popular' },
            { value: 'recent', label: '🆕 Recent' },
            { value: 'rating', label: '⭐ Top Rated' },
        ],
        features: [],
        hasSortDirection: false,
        hasTokenFilters: false,
        extraToggles: [],
        nsfwAvailable: false,
        nsfwMode: 'wyvern',
        nsfwHint: 'PlotLight decides what you can see without an account, and adult-tagged results are marked NSFW.',
        async search(p) {
            try {
                const { items, hasMore } = await plotlightClient.searchPage({ type, query: p.query, sort: p.sort, includeTags: p.includeTags, excludeTags: p.excludeTags }, p.page);
                return {
                    totalCount: 0,
                    hasMore,
                    cards: items.map(item => ({
                        id: item.id, name: item.name, creator: item.creator, tagline: item.description.slice(0, 200),
                        tags: item.tags.map(tag => tag.name), avatarUrl: item.imageUrl,
                        stat1: 0, stat1Label: '', stat1Icon: 'star', stat2: 0, stat2Label: '', stat2Icon: 'star', stat3: 0, stat3Label: '', stat3Icon: 'star',
                        nsfw: item.adult, externalUrl: item.detailUrl, _raw: item,
                    })),
                };
            } catch (error) {
                throw plotlightUserError(error, false);
            }
        },
        async fetchDetail(card) {
            try {
                return readCharacterCardDetailFields((await plotlightClient.downloadCard(card._raw, detailFormats)).json);
            } catch (error) {
                throw plotlightUserError(error);
            }
        },
        async downloadCard(card) {
            try {
                return await plotlightClient.downloadCard(card._raw, importFormats);
            } catch (error) {
                throw plotlightUserError(error);
            }
        },
    };
}

const ALL_PROVIDERS = [
    chubProvider,
    jannyProvider,
    chartavernProvider,
    pygmalionProvider,
    wyvernProvider,
    datacatProvider,
    createPlotlightProvider('cards'),
    createPlotlightProvider('personas'),
];
const getProvider = id => ALL_PROVIDERS.find(p => p.id === id) ?? chubProvider;

// ════════════════════════════════════════════════
// State
// ════════════════════════════════════════════════

const TAG_IMPORT_OPTIONS = [
    { value: 'all', label: 'All tags', description: 'Keep source tags.' },
    { value: 'none', label: 'No tags', description: 'Skip source tags.' },
    { value: 'existing', label: 'Existing only', description: 'Keep tags already in SillyTavern.' },
];

const STAT_ICONS = { star: 'fa-star', download: 'fa-download', heart: 'fa-heart', eye: 'fa-eye', message: 'fa-comment', hash: 'fa-hashtag' };

const state = {
    sourceId: 'chub',
    sourceOpen: false,
    query: '',
    sort: chubProvider.defaultSort,
    sortAsc: false,
    page: 1,
    nsfw: getPersistNsfw('chub'),
    tagSearch: '',
    includeTags: [],
    excludeTags: [],
    showTagPanel: false,
    availableTags: [],
    showFiltersPanel: false,
    minTokens: '',
    maxTokens: '',
    features: {},
    extraToggles: {},
    results: [],
    totalCount: 0,
    hasMore: undefined,
    loading: false,
    error: null,
    selectedCard: null,
    detail: null,
    detailLoading: false,
    importing: false,
    pendingImport: null,
    tagImportMode: 'all',
    showLoginModal: false,
    pygLoggedIn: getPersistLogin('pygmalion'),
    loginLoading: false,
    datacatNsfwAcked: false,
    pendingDatacatSwitch: false,
    zoomed: false,
    downloading: false,
};

let root = null;
let searchTimer = null;
let searchSeq = 0;
let resultsScrollTop = 0;

const provider = () => getProvider(state.sourceId);
const needsPluginNotice = () => provider().needsPlugin && !pluginAvailable;

function effectiveNsfwAvailable() {
    const p = provider();
    if (p.nsfwMode === 'free') return true;
    if (p.nsfwMode === 'wyvern') return false;
    if (p.nsfwMode === 'login' && state.sourceId === 'pygmalion') return state.pygLoggedIn;
    return p.nsfwAvailable;
}

function setNsfw(value) {
    state.nsfw = value;
    setPersistNsfw(state.sourceId, value);
}

function setPygLoggedIn(value) {
    state.pygLoggedIn = value;
    setPersistLogin('pygmalion', value);
}

function totalPages() {
    if (state.hasMore === undefined) return Math.max(1, Math.ceil(state.totalCount / provider().pageSize));
    return state.hasMore ? state.page + 1 : state.page;
}

// ════════════════════════════════════════════════
// Search, details, import
// ════════════════════════════════════════════════

function scheduleSearch() {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(doSearch, state.query ? 400 : 0);
}

function mergeAvailableTags(tags) {
    const merged = new Set([...state.availableTags, ...tags]);
    state.availableTags = [...merged].sort((a, b) => a.localeCompare(b));
}

async function doSearch() {
    const p = provider();
    if (p.unavailable || needsPluginNotice()) return;
    const seq = ++searchSeq;
    state.loading = true;
    state.error = null;
    renderResults();
    try {
        const result = await p.search({
            query: state.query, page: state.page, sort: state.sort, nsfw: state.nsfw, includeTags: state.includeTags,
            excludeTags: state.excludeTags, sortAsc: state.sortAsc, minTokens: state.minTokens, maxTokens: state.maxTokens,
            features: state.features, extraToggles: state.extraToggles,
        });
        // a newer search or a source switch started meanwhile
        if (seq !== searchSeq) return;
        state.results = result.cards;
        state.totalCount = result.totalCount;
        state.hasMore = result.hasMore;
        mergeAvailableTags(result.cards.flatMap(card => card.tags || []));
    } catch (err) {
        if (seq !== searchSeq) return;
        if (err instanceof PygmalionSessionExpiredError) expirePygmalionSession();
        else state.error = err instanceof Error ? err.message : 'Search failed';
        state.results = [];
    } finally {
        if (seq === searchSeq) {
            state.loading = false;
            withFocus(() => {
                renderHeader();
                renderTagPanel();
                renderResults();
            });
        }
    }
}

function expirePygmalionSession() {
    setPygLoggedIn(false);
    setPersistNsfw('pygmalion', false);
    if (state.sourceId === 'pygmalion') state.nsfw = false;
    toastr.info('Pygmalion session expired, please log in again.');
    render();
}

function performSwitch(newId) {
    const next = getProvider(newId);
    searchSeq++;
    Object.assign(state, {
        sourceId: newId, sourceOpen: false, query: '', sort: next.defaultSort, sortAsc: false, page: 1,
        // DataCat is NSFW-only: every character is tagged NSFW upstream
        nsfw: newId === 'datacat' ? true : getPersistNsfw(newId),
        includeTags: [], excludeTags: [], tagSearch: '', availableTags: [], showTagPanel: false, showFiltersPanel: false,
        minTokens: '', maxTokens: '', features: {}, extraToggles: {}, results: [], totalCount: 0, hasMore: undefined,
        error: null, loading: false, selectedCard: null, detail: null, showLoginModal: false,
    });
    render();
    if (newId === 'datacat' && pluginAvailable) {
        loadDatacatTags().then(() => {
            if (state.sourceId !== 'datacat' || !datacatTopTagNames.length) return;
            mergeAvailableTags(datacatTopTagNames);
            withFocus(renderTagPanel);
        });
    }
    scheduleSearch();
}

function switchProvider(newId) {
    if (newId === 'datacat' && !state.datacatNsfwAcked) {
        state.sourceOpen = false;
        state.pendingDatacatSwitch = true;
        render();
        return;
    }
    performSwitch(newId);
}

async function openDetail(card) {
    resultsScrollTop = root?.querySelector('.cb-main')?.scrollTop ?? 0;
    Object.assign(state, { selectedCard: card, detail: null, detailLoading: true, zoomed: false });
    renderMain(true);
    try {
        const detail = await provider().fetchDetail(card);
        if (state.selectedCard !== card) return;
        state.detail = detail;
    } catch (err) {
        if (state.selectedCard !== card) return;
        if (err instanceof BrowserSourceError) {
            // keep the page: its picture, creator and site link come from the listing
            toastr.error(err.message);
        } else {
            if (err instanceof PygmalionSessionExpiredError) expirePygmalionSession();
            else toastr.error('Failed to load character details');
            state.selectedCard = null;
        }
    } finally {
        if (state.selectedCard === card || state.selectedCard === null) {
            state.detailLoading = false;
            renderMain(state.selectedCard === null ? 'restore' : false);
        }
    }
}

function closeDetail() {
    Object.assign(state, { selectedCard: null, detail: null, zoomed: false });
    renderMain('restore');
}

async function prepareCardImport(card) {
    const p = provider();
    if (p.downloadCard) {
        const { json, bytes } = await p.downloadCard(card);
        return { card, json, pngBytes: bytes, embeddedLorebook: readCharacterCardData(json).character_book };
    }
    let downloadUrl = state.sourceId === 'chub' ? p.downloadUrl(card) : '';
    let prefetched = null;
    if (state.sourceId === 'janny') {
        try {
            const response = await fetchCompleteJannyCard(card.id);
            if (!response.ok) throw new Error('JannyAI character-card download failed');
            const parsed = await parsePngCharacterCard(await response.blob());
            if (!hasJannyCharacterDefinition(readCharacterCardDetailFields(parsed.json))) throw new Error('JannyAI character-card definition is incomplete');
            prefetched = parsed;
            downloadUrl = 'janny';
        } catch {
            downloadUrl = '';
        }
    }
    if (downloadUrl) {
        let parsed = prefetched;
        if (state.sourceId !== 'janny') {
            const response = await fetch(downloadUrl, { headers: pluginAvailable ? getRequestHeaders() : {}, referrerPolicy: 'no-referrer' });
            if (!response.ok) throw new Error('Import failed');
            parsed = await parsePngCharacterCard(await response.blob());
        }
        const detail = state.sourceId === 'chub' ? (state.detail ?? await p.fetchDetail(card)) : state.detail;
        const withLorebook = attachEmbeddedLorebook(parsed.json, detail?.embeddedLorebook);
        const json = state.sourceId === 'chub' ? mergeChubDetail(withLorebook, { name: card.name, creator: card.creator, tags: card.tags }, detail) : withLorebook;
        return { card, json, pngBytes: parsed.bytes, embeddedLorebook: detail?.embeddedLorebook ?? readCharacterCardData(json).character_book };
    }
    let detail = state.detail;
    if (state.sourceId === 'janny' && !hasJannyCharacterDefinition(detail)) detail = await p.fetchDetail(card, { skipCompleteCard: true });
    else if (!detail) detail = await p.fetchDetail(card);
    if (state.sourceId === 'janny' && !hasJannyCharacterDefinition(detail)) {
        throw new Error("JannyAI blocked access to this card's full definition. Open the card on JannyAI, download its PNG, then import that file in SillyTavern.");
    }
    const description = detail?.description || '';
    const personality = detail?.personality || '';
    const fields = {
        name: card.name,
        description: description || personality,
        personality: personality && description ? personality : '',
        scenario: detail?.scenario || '',
        first_mes: detail?.firstMessage || '',
        mes_example: detail?.exampleDialogs || '',
        creator_notes: detail?.creatorNotes || '',
        system_prompt: detail?.systemPrompt || '',
        post_history_instructions: detail?.postHistoryInstructions || '',
        character_version: detail?.characterVersion || '',
        tags: card.tags,
        creator: card.creator,
        alternate_greetings: detail?.alternateGreetings || [],
        extensions: { [state.sourceId]: { id: card.id } },
    };
    if (hasLorebookEntries(detail?.embeddedLorebook)) fields.character_book = detail.embeddedLorebook;
    return { card, json: toV2Card(fields), pngBytes: undefined, embeddedLorebook: detail?.embeddedLorebook };
}

/** The card's own PNG when there is one, else its avatar, else SillyTavern's default avatar. */
async function portraitPng(prepared, fallback) {
    if (prepared.pngBytes) return prepared.pngBytes;
    for (const source of [prepared.card.avatarUrl, fallback]) {
        if (!source) continue;
        try {
            return await imageToPngBytes(source);
        } catch { /* try the next */ }
    }
    throw new Error('Could not load any image for the card');
}

async function importLorebook(book, fallbackName) {
    const name = optionalString(book?.name) ?? fallbackName;
    await saveWorldInfo(name, convertCharacterBook(book), true);
    await updateWorldInfoList();
    return name;
}

async function importAsCharacter(prepared, withLorebook) {
    const card = asCard(prepared.json);
    const data = card.data;
    if (withLorebook && hasLorebookEntries(prepared.embeddedLorebook)) {
        if (!hasLorebookEntries(data.character_book)) data.character_book = prepared.embeddedLorebook;
        const bookName = await importLorebook(data.character_book, `${data.name || prepared.card.name}'s Lorebook`);
        // linking the imported book also stops SillyTavern from offering to import it again
        data.extensions = { ...(optionalRecord(data.extensions) ?? {}), world: bookName };
        toastr.success(`Lorebook "${bookName}" imported and linked.`);
    } else {
        delete data.character_book;
    }
    const png = writeCardIntoPng(await portraitPng(prepared, default_avatar), card);
    const file = new File([png], `${(data.name || prepared.card.name || 'character').replace(/[^a-zA-Z0-9_-]/g, '_')}.png`, { type: 'image/png' });
    // SillyTavern's own tag import applies the chosen mode, then puts the setting back
    const previous = power_user.tag_import_setting;
    power_user.tag_import_setting = { all: tag_import_setting.ALL, none: tag_import_setting.NONE, existing: tag_import_setting.ONLY_EXISTING }[state.tagImportMode];
    try {
        await processDroppedFiles([file]);
    } finally {
        power_user.tag_import_setting = previous;
    }
}

async function importAsPersona(prepared, withLorebook) {
    const data = readCharacterCardData(prepared.json);
    const name = optionalString(data.name) ?? prepared.card.name;
    const description = optionalString(data.description) ?? optionalString(data.personality) ?? '';
    let lorebook = '';
    if (withLorebook && hasLorebookEntries(prepared.embeddedLorebook)) {
        try {
            lorebook = await importLorebook(prepared.embeddedLorebook, `${name}'s Lorebook`);
        } catch {
            toastr.warning('The persona was imported, but its embedded lorebook could not be imported.');
        }
    }
    const avatarId = `${Date.now()}-${name.replace(/[^a-zA-Z0-9]/g, '')}.png`;
    let png;
    try {
        png = await portraitPng({ ...prepared, pngBytes: undefined }, null);
    } catch {
        toastr.warning('The persona was imported, but its avatar could not be copied.');
        png = await imageToPngBytes(default_user_avatar);
    }
    const form = new FormData();
    form.append('avatar', new File([png], 'avatar.png', { type: 'image/png' }));
    form.append('overwrite_name', avatarId);
    const response = await fetch('/api/avatars/upload', { method: 'POST', headers: getRequestHeaders({ omitContentType: true }), cache: 'no-cache', body: form });
    if (!response.ok) throw new Error(`Failed to upload persona avatar: ${response.statusText}`);
    const uploaded = await response.json().catch(() => ({}));
    const finalId = uploaded?.path || avatarId;
    await initPersona(finalId, name, description, '', { lorebook });
    await getUserAvatars(true, finalId);
    toastr.success(`Imported "${name}" as a persona.`);
}

async function importPrepared(prepared, target, withLorebook) {
    if (target === 'character') await importAsCharacter(prepared, withLorebook);
    else await importAsPersona(prepared, withLorebook);
}

async function chooseImportTarget(target) {
    const pending = state.pendingImport;
    if (!pending) return;
    state.pendingImport = { card: pending.card, target };
    state.importing = true;
    renderModals();
    try {
        const prepared = await prepareCardImport(pending.card);
        if (hasLorebookEntries(prepared.embeddedLorebook)) {
            state.pendingImport = { card: pending.card, target, prepared };
            return;
        }
        await importPrepared(prepared, target, false);
        state.pendingImport = null;
    } catch (error) {
        state.pendingImport = { card: pending.card };
        if (error instanceof PygmalionSessionExpiredError) expirePygmalionSession();
        else toastr.error(error instanceof Error ? error.message : 'Import failed');
    } finally {
        state.importing = false;
        renderModals();
        renderMain(false);
    }
}

async function finishImport(withLorebook) {
    const pending = state.pendingImport;
    if (!pending?.target || !pending.prepared) return;
    state.importing = true;
    renderModals();
    try {
        await importPrepared(pending.prepared, pending.target, withLorebook);
        state.pendingImport = null;
    } catch (error) {
        if (error instanceof PygmalionSessionExpiredError) expirePygmalionSession();
        else toastr.error(error instanceof Error ? error.message : 'Import failed');
    } finally {
        state.importing = false;
        renderModals();
    }
}

async function downloadPng() {
    const card = state.selectedCard;
    if (!card) return;
    state.downloading = true;
    renderMain(false);
    try {
        let detail = state.detail;
        if (!detail && !state.detailLoading) {
            detail = await provider().fetchDetail(card);
            if (detail && state.selectedCard === card) state.detail = detail;
        }
        const description = detail?.description || '';
        const personality = detail?.personality || '';
        const fields = {
            name: card.name,
            description: description || personality,
            personality: personality && description ? personality : '',
            scenario: detail?.scenario || '',
            first_mes: detail?.firstMessage || '',
            mes_example: detail?.exampleDialogs || '',
            creator_notes: detail?.creatorNotes || '',
            system_prompt: detail?.systemPrompt || '',
            post_history_instructions: detail?.postHistoryInstructions || '',
            character_version: detail?.characterVersion || '',
            tags: card.tags || [],
            creator: card.creator || '',
            alternate_greetings: detail?.alternateGreetings || [],
            extensions: { [provider().id]: { id: card.id } },
        };
        if (hasLorebookEntries(detail?.embeddedLorebook)) fields.character_book = detail.embeddedLorebook;
        const png = writeCardIntoPng(await imageToPngBytes(card.avatarUrl), toV2Card(fields));
        downloadBlob(new Blob([png], { type: 'image/png' }), `${(card.name || 'character').replace(/[^a-zA-Z0-9_-]/g, '_')}.png`);
        toastr.success(`Downloaded "${card.name}" as PNG character card!`);
    } catch (err) {
        if (err instanceof PygmalionSessionExpiredError) expirePygmalionSession();
        else toastr.error(err instanceof Error ? err.message : 'Download failed');
    } finally {
        state.downloading = false;
        renderMain(false);
    }
}

async function pygmalionSetToken(token) {
    state.loginLoading = true;
    renderModals();
    try {
        const res = await pluginFetch('/pygmalion/set-token', { method: 'POST', body: JSON.stringify({ token }) });
        const data = await res.json().catch(() => null);
        if (typeof data?.active === 'boolean') setPygLoggedIn(data.active);
        if (!res.ok || !data?.ok) throw new Error(PYGMALION_LOGIN_FAILURES[data?.reason] ?? 'Token validation failed');
        state.showLoginModal = false;
        setNsfw(true);
        state.page = 1;
        toastr.success('Logged in to Pygmalion! NSFW content enabled.');
        scheduleSearch();
    } catch (err) {
        toastr.error(err instanceof Error ? err.message : 'Token validation failed');
    } finally {
        state.loginLoading = false;
        render();
    }
}

async function pygmalionLogout() {
    await pluginFetch('/pygmalion/logout', { method: 'POST' }).catch(() => null);
    setPygLoggedIn(false);
    setNsfw(false);
    state.page = 1;
    state.showLoginModal = false;
    toastr.info('Logged out of Pygmalion.');
    render();
    scheduleSearch();
}

// ════════════════════════════════════════════════
// Rendering
// ════════════════════════════════════════════════

/** Re-renders a region while keeping the focused input and its caret. */
function withFocus(fn) {
    const active = document.activeElement;
    const key = active?.dataset?.focusKey;
    const start = active?.selectionStart;
    const end = active?.selectionEnd;
    fn();
    if (!key || !root) return;
    const next = root.querySelector(`[data-focus-key="${key}"]`);
    if (next && next !== document.activeElement) {
        next.focus();
        try {
            next.setSelectionRange(start, end);
        } catch { /* not a text input */ }
    }
}

function render() {
    if (!root) return;
    withFocus(() => {
        renderHeader();
        renderTagPanel();
        renderMain(false);
        renderModals();
    });
}

function renderHeader() {
    const p = provider();
    const header = root.querySelector('.cb-header');
    const subtitle = p.unavailable || needsPluginNotice() ? esc(p.name)
        : state.totalCount > 0 ? `${state.totalCount.toLocaleString()} cards from ${esc(p.name)}` : `Browsing ${esc(p.name)}`;
    header.innerHTML = `
        <div class="cb-header-left">
            <button type="button" class="menu_button cb-icon-button" data-action="close" title="Close library"><i class="fa-solid fa-arrow-left"></i></button>
            <div class="cb-titles">
                <p class="cb-kicker">Cards Library</p>
                <h1>Browse character cards online</h1>
                <p class="cb-subtitle">${subtitle}</p>
            </div>
        </div>
        <div class="cb-header-right">
            <button type="button" class="menu_button cb-source-button" data-action="toggle-source">
                <span>${esc(p.icon)}</span><span>${esc(p.name)}</span><i class="fa-solid fa-chevron-down ${state.sourceOpen ? 'cb-rotated' : ''}"></i>
            </button>
            ${state.sourceId === 'pygmalion' && state.pygLoggedIn ? '<span class="cb-logged-in"><i class="fa-solid fa-circle-check"></i> Logged in</span>' : ''}
            ${state.sourceOpen ? `
                <div class="cb-source-backdrop" data-action="close-source"></div>
                <div class="cb-source-menu">
                    ${ALL_PROVIDERS.map(x => `
                        <button type="button" class="cb-source-item ${x.id === state.sourceId ? 'cb-active' : ''}" data-action="switch-source" data-id="${x.id}">
                            <span class="cb-source-icon">${esc(x.icon)}</span>
                            <span class="cb-source-name">${esc(x.name)}${x.unavailable ? '<small>Unavailable</small>' : x.needsPlugin && !pluginAvailable ? '<small>Needs the server plugin</small>' : ''}</span>
                            ${x.id === state.sourceId ? '<span class="cb-check">✓</span>' : ''}
                        </button>`).join('')}
                </div>` : ''}
        </div>`;
}

function renderTagPanel() {
    const aside = root.querySelector('.cb-tags');
    aside.hidden = !state.showTagPanel;
    if (!state.showTagPanel) {
        aside.innerHTML = '';
        return;
    }
    const q = state.tagSearch.trim().toLowerCase();
    const filtered = q ? state.availableTags.filter(t => t.toLowerCase().includes(q)) : state.availableTags;
    const canAdd = q.length >= 2 && !state.includeTags.includes(q);
    const anyActive = state.includeTags.length || state.excludeTags.length;
    aside.innerHTML = `
        <div class="cb-tags-head">
            <span><i class="fa-solid fa-tag"></i> Tags</span>
            <span>
                ${anyActive ? '<button type="button" class="menu_button cb-small cb-danger" data-action="clear-tags">Clear</button>' : ''}
                <button type="button" class="menu_button cb-small" data-action="toggle-tags"><i class="fa-solid fa-xmark"></i></button>
            </span>
        </div>
        <div class="cb-tags-search"><input type="text" class="text_pole" data-focus-key="tag-search" data-input="tag-search" value="${esc(state.tagSearch)}" placeholder="Search tags"></div>
        ${anyActive ? `<div class="cb-chips">
            ${state.includeTags.map(t => `<span class="cb-chip cb-include" data-action="toggle-include" data-tag="${esc(t)}">+ ${esc(t)}</span>`).join('')}
            ${state.excludeTags.map(t => `<span class="cb-chip cb-exclude" data-action="toggle-exclude" data-tag="${esc(t)}">− ${esc(t)}</span>`).join('')}
        </div>` : ''}
        <div class="cb-tags-list">
            ${canAdd ? `
                <button type="button" class="cb-add-tag cb-include" data-action="add-custom-include">+ Add <strong>${esc(q)}</strong> as filter</button>
                <button type="button" class="cb-add-tag cb-exclude" data-action="add-custom-exclude">− Block <strong>${esc(q)}</strong> from results</button>` : ''}
            ${filtered.length === 0 && !canAdd
        ? `<div class="cb-empty-note">${state.availableTags.length === 0 ? 'Tags will appear after searching' : 'No tags match filter'}</div>`
        : filtered.map(tag => {
            const inc = state.includeTags.includes(tag);
            const exc = state.excludeTags.includes(tag);
            return `<div class="cb-tag-row">
                        <button type="button" class="cb-tag-box ${inc ? 'cb-on-include' : ''}" data-action="toggle-include" data-tag="${esc(tag)}">${inc ? '✓' : ''}</button>
                        <span class="cb-tag-name">${esc(tag)}</span>
                        <button type="button" class="cb-tag-box cb-minus ${exc ? 'cb-on-exclude' : ''}" data-action="toggle-exclude" data-tag="${esc(tag)}">−</button>
                    </div>`;
        }).join('')}
        </div>`;
}

function statsHtml(card, long = false) {
    return [1, 2, 3].map(i => {
        const value = card[`stat${i}`];
        const label = card[`stat${i}Label`];
        if (!(value > 0 && label)) return '';
        return `<span title="${esc(label)}"><i class="fa-solid ${STAT_ICONS[card[`stat${i}Icon`]] ?? 'fa-star'}"></i> ${fmtNum(value)}${long ? ` ${esc(label.toLowerCase())}` : ''}</span>`;
    }).join('');
}

function avatarHtml(url, alt, cls = '') {
    return url
        ? `<img class="${cls}" src="${esc(url)}" alt="${esc(alt)}" loading="lazy" referrerpolicy="no-referrer" data-fallback>`
        : '<div class="cb-avatar-fallback"><i class="fa-solid fa-hashtag"></i></div>';
}

function toolbarHtml() {
    const p = provider();
    const groups = [];
    for (const opt of p.sortOptions) {
        let group = groups.find(g => g.label === (opt.group || ''));
        if (!group) groups.push(group = { label: opt.group || '', options: [] });
        group.options.push(opt);
    }
    const sortSelect = `<select class="text_pole cb-sort" data-input="sort">${groups.map(g => {
        const options = g.options.map(o => `<option value="${esc(o.value)}" ${o.value === state.sort ? 'selected' : ''}>${esc(o.label)}</option>`).join('');
        return g.label ? `<optgroup label="${esc(g.label)}">${options}</optgroup>` : options;
    }).join('')}</select>`;
    const tagCount = state.includeTags.length + state.excludeTags.length;
    const activeFeatures = p.features.filter(f => state.features[f.key]).length + p.extraToggles.filter(t => state.extraToggles[t.key]).length;
    const hasFilters = p.features.length || p.hasSortDirection || p.hasTokenFilters || p.extraToggles.length;
    const isLogin = p.nsfwMode === 'login';
    const greyed = isLogin && state.sourceId === 'pygmalion' && state.pygLoggedIn;
    const available = effectiveNsfwAvailable();
    const nsfwTitle = greyed ? 'NSFW depends on your account settings'
        : available ? 'Toggle NSFW content'
            : p.nsfwHint ? p.nsfwHint
                : state.sourceId === 'wyvern' ? 'Use the "Popular NSFW" sort option'
                    : state.sourceId === 'datacat' ? 'DataCat is NSFW-only'
                        : `Click to log in to ${p.name} for NSFW content`;
    return `
        <div class="cb-toolbar">
            <div class="cb-search">
                <i class="fa-solid fa-magnifying-glass"></i>
                <input type="text" class="text_pole" data-focus-key="query" data-input="query" value="${esc(state.query)}" placeholder="Search characters">
                ${state.query ? '<button type="button" class="cb-clear" data-action="clear-query"><i class="fa-solid fa-xmark"></i></button>' : ''}
            </div>
            ${sortSelect}
            <button type="button" class="menu_button ${state.showTagPanel || tagCount ? 'cb-selected' : ''}" data-action="toggle-tags">
                <i class="fa-solid fa-tag"></i> Tags ${tagCount ? `<span class="cb-badge">${tagCount}</span>` : ''}
            </button>
            ${hasFilters ? `<button type="button" class="menu_button ${state.showFiltersPanel || activeFeatures ? 'cb-selected' : ''}" data-action="toggle-filters">
                <i class="fa-solid fa-sliders"></i> Filters ${activeFeatures ? `<span class="cb-badge">${activeFeatures}</span>` : ''}
            </button>` : ''}
            <label class="menu_button cb-nsfw ${greyed ? 'cb-disabled' : available ? '' : 'cb-dim'}" title="${esc(nsfwTitle)}" data-action="nsfw-label">
                <input type="checkbox" data-input="nsfw" ${greyed || state.nsfw ? 'checked' : ''} ${greyed || !available ? 'disabled' : ''}> NSFW
                ${greyed ? '<small>(account)</small>' : ''}
                ${!greyed && isLogin && !available ? '<i class="fa-solid fa-right-to-bracket"></i>' : ''}
            </label>
            ${isLogin ? (state.sourceId === 'pygmalion' && state.pygLoggedIn
        ? `<span class="cb-info-pill cb-green"><i class="fa-solid fa-circle-check"></i> NSFW depends on your account settings</span>
                   <button type="button" class="menu_button cb-small" data-action="pyg-logout" title="Log out"><i class="fa-solid fa-right-from-bracket"></i> Logout</button>`
        : '<button type="button" class="menu_button" data-action="open-login"><i class="fa-solid fa-right-to-bracket"></i> Log In</button>') : ''}
            ${state.sourceId === 'wyvern' ? '<span class="cb-info-pill cb-amber">Use "🔞 Popular NSFW" sort for NSFW content</span>' : ''}
            <button type="button" class="menu_button cb-icon-button" data-action="refresh" title="Refresh"><i class="fa-solid fa-rotate-right"></i></button>
        </div>
        ${state.showFiltersPanel ? `<div class="cb-filters">
            ${p.features.length || p.extraToggles.length ? `<div class="cb-filter-col">
                <span class="cb-filter-title">Character Must Have</span>
                ${p.features.map(f => `<label><input type="checkbox" data-input="feature" data-key="${f.key}" ${state.features[f.key] ? 'checked' : ''}> ${esc(f.icon)} ${esc(f.label)}</label>`).join('')}
                ${p.extraToggles.map(t => `<label><input type="checkbox" data-input="extra" data-key="${t.key}" ${state.extraToggles[t.key] ? 'checked' : ''}> ${esc(t.icon)} ${esc(t.label)}</label>`).join('')}
            </div>` : ''}
            ${p.hasSortDirection || p.hasTokenFilters ? `<div class="cb-filter-col">
                <span class="cb-filter-title">Advanced Options</span>
                ${p.hasSortDirection ? `<div class="cb-filter-row"><span>Sort Direction</span><select class="text_pole" data-input="sort-dir">
                    <option value="desc" ${state.sortAsc ? '' : 'selected'}>Descending</option><option value="asc" ${state.sortAsc ? 'selected' : ''}>Ascending</option></select></div>` : ''}
                ${p.hasTokenFilters ? `
                    <div class="cb-filter-row"><span>Min Tokens</span><input type="number" class="text_pole" data-focus-key="min-tokens" data-input="min-tokens" value="${esc(state.minTokens)}" placeholder="50"></div>
                    <div class="cb-filter-row"><span>Max Tokens</span><input type="number" class="text_pole" data-focus-key="max-tokens" data-input="max-tokens" value="${esc(state.maxTokens)}" placeholder="100000"></div>` : ''}
            </div>` : ''}
        </div>` : ''}
        <div class="cb-results"></div>`;
}

function renderResults() {
    const container = root?.querySelector('.cb-results');
    if (!container) return;
    if (state.loading) {
        container.innerHTML = '<div class="cb-center"><i class="fa-solid fa-spinner fa-spin"></i></div>';
        return;
    }
    if (state.error) {
        container.innerHTML = `<div class="cb-center cb-column"><span class="cb-error">${esc(state.error)}</span>
            <button type="button" class="menu_button cb-selected" data-action="refresh"><i class="fa-solid fa-rotate-right"></i> Retry</button></div>`;
        return;
    }
    const pages = totalPages();
    const grid = state.results.length === 0
        ? '<div class="cb-center cb-muted">No characters found</div>'
        : `<div class="cb-grid">${state.results.map((card, i) => `
            <button type="button" class="cb-tile" data-action="open-card" data-index="${i}">
                <div class="cb-tile-image">${avatarHtml(card.avatarUrl, card.name)}${card.nsfw ? '<span class="cb-nsfw-badge">NSFW</span>' : ''}</div>
                <div class="cb-tile-body">
                    <h3>${esc(card.name)}</h3>
                    ${card.creator ? `<p class="cb-muted">by ${esc(card.creator)}</p>` : ''}
                    ${card.tagline ? `<p class="cb-tagline">${esc(card.tagline)}</p>` : ''}
                    <div class="cb-stats">${statsHtml(card)}</div>
                </div>
            </button>`).join('')}</div>`;
    const pager = pages > 1 || state.page > 1 ? `<div class="cb-pager">
            <button type="button" class="menu_button cb-small" data-action="prev-page" ${state.page <= 1 ? 'disabled' : ''}>Previous</button>
            ${state.hasMore === undefined && pages > 1 && pages < 9000
        ? `<label class="cb-muted">Page <select class="text_pole" data-input="page">${Array.from({ length: pages }, (_, i) => `<option value="${i + 1}" ${i + 1 === state.page ? 'selected' : ''}>${i + 1}</option>`).join('')}</select> of ${pages}</label>`
        : `<span class="cb-muted">Page ${state.page}</span>`}
            <button type="button" class="menu_button cb-small" data-action="next-page" ${state.page >= pages && pages > 1 ? 'disabled' : ''}>Next</button>
        </div>` : '';
    container.innerHTML = grid + pager;
}

function noticeHtml(p) {
    if (p.unavailable) {
        return `<div class="cb-notice">
            <div class="cb-notice-icon"><i class="fa-solid fa-plug-circle-xmark"></i></div>
            <h2>${esc(p.name)} can't be browsed here for now</h2>
            <p>${esc(p.unavailable.notice)}</p>
            <div class="cb-notice-actions">
                <a class="menu_button" href="${esc(p.unavailable.siteUrl)}" target="_blank" rel="noopener noreferrer"><i class="fa-solid fa-arrow-up-right-from-square"></i> Open ${esc(p.siteName)}</a>
                <button type="button" class="menu_button" data-action="st-import"><i class="fa-solid fa-file-import"></i> Import Character</button>
            </div></div>`;
    }
    return `<div class="cb-notice">
        <div class="cb-notice-icon"><i class="fa-solid fa-server"></i></div>
        <h2>${esc(p.name)} needs the Card Browser server plugin</h2>
        <p>${esc(p.name)} refuses requests from a browser page, so SillyTavern has to fetch it on your behalf. Install the <code>cardbrowser</code> server plugin and set <code>enableServerPlugins: true</code> in config.yaml, then restart SillyTavern.</p>
        <div class="cb-notice-actions"><a class="menu_button" href="${esc(p.id === 'pygmalion' ? 'https://pygmalion.chat' : p.id === 'wyvern' ? 'https://app.wyvern.chat' : 'https://datacat.run')}" target="_blank" rel="noopener noreferrer"><i class="fa-solid fa-arrow-up-right-from-square"></i> Open ${esc(p.siteName)}</a></div>
    </div>`;
}

function defSection(title, content, allowHtml = false) {
    let body;
    if (allowHtml && /<[a-z][\s\S]*>/i.test(content) && window.DOMPurify) {
        body = `<div class="cb-def-body cb-rich">${window.DOMPurify.sanitize(content, { FORBID_TAGS: ['style', 'script', 'iframe', 'form', 'input', 'button', 'link', 'meta'], FORBID_ATTR: ['srcset'] })}</div>`;
    } else {
        body = `<div class="cb-def-body">${esc(content)}</div>`;
    }
    return `<div class="cb-def"><h4>${esc(title)}</h4>${body}</div>`;
}

function detailHtml() {
    const card = state.selectedCard;
    const p = provider();
    const d = state.detail;
    const head = `<div class="cb-detail-top">
            <button type="button" class="menu_button cb-icon-button" data-action="back" title="Back to results"><i class="fa-solid fa-arrow-left"></i></button>
            <div class="cb-flex1"></div>
            <a class="menu_button cb-small" href="${esc(card.externalUrl)}" target="_blank" rel="noopener noreferrer"><i class="fa-solid fa-arrow-up-right-from-square"></i> View on ${esc(p.siteName)}</a>
        </div>`;
    if (state.detailLoading) return `${head}<div class="cb-center"><i class="fa-solid fa-spinner fa-spin"></i></div>`;
    const sections = d ? [
        d.creatorNotes ? defSection("Creator's Notes", d.creatorNotes, true) : '',
        d.description ? defSection('Description / Personality', d.description) : '',
        d.personality ? defSection('Personality', d.personality) : '',
        d.scenario ? defSection('Scenario', d.scenario) : '',
        d.firstMessage ? defSection('First Message', d.firstMessage) : '',
        d.alternateGreetings?.length ? `<div class="cb-def"><h4>Alternate Greetings (${d.alternateGreetings.length})</h4>
            ${d.alternateGreetings.map(g => `<div class="cb-def-body cb-greeting">${esc(g)}</div>`).join('')}</div>` : '',
        d.exampleDialogs ? defSection('Example Dialogues', d.exampleDialogs) : '',
        d.hasLorebook ? '<div class="cb-lore-pill"><i class="fa-solid fa-circle-check"></i> Has embedded lorebook</div>' : '',
        ...(d.extra ?? []).map(s => defSection(s.title, s.content)),
    ].join('') : '<div class="cb-muted cb-italic">No detailed definition available. You can still import this character with basic info.</div>';
    return `${head}
        <div class="cb-detail">
            <div class="cb-detail-side">
                <div class="cb-detail-image">${card.avatarUrl ? `<button type="button" class="cb-zoom" data-action="zoom" title="Enlarge image">${avatarHtml(card.avatarUrl, card.name)}</button>` : avatarHtml('', card.name)}</div>
                <div class="cb-detail-actions">
                    <div class="cb-tag-mode">
                        <p>Imported tags</p>
                        ${TAG_IMPORT_OPTIONS.map(o => `<label class="${state.tagImportMode === o.value ? 'cb-on' : ''}">
                            <input type="radio" name="cb-tag-mode" data-input="tag-mode" value="${o.value}" ${state.tagImportMode === o.value ? 'checked' : ''}>
                            <span>${esc(o.label)}</span><small>${esc(o.description)}</small></label>`).join('')}
                    </div>
                    <button type="button" class="menu_button cb-primary" data-action="import" ${state.importing ? 'disabled' : ''}>
                        <i class="fa-solid ${state.importing ? 'fa-spinner fa-spin' : 'fa-download'}"></i> <span>${state.importing ? 'Importing...' : 'Import'}</span>
                    </button>
                    <button type="button" class="menu_button" data-action="download-png" ${state.downloading ? 'disabled' : ''}>
                        <i class="fa-solid ${state.downloading ? 'fa-spinner fa-spin' : 'fa-download'}"></i> <span>${state.downloading ? 'Building PNG...' : 'Download as PNG'}</span>
                    </button>
                    ${statsHtml(card) ? `<div class="cb-detail-stats">${statsHtml(card, true)}</div>` : ''}
                </div>
            </div>
            <div class="cb-detail-main">
                <div><h3>${esc(card.name)}</h3>${card.creator ? `<p class="cb-muted">by ${esc(card.creator)}</p>` : ''}</div>
                ${card.tagline ? `<p class="cb-tagline-full">${esc(card.tagline)}</p>` : ''}
                ${card.tags?.length ? `<div class="cb-card-tags">${card.tags.slice(0, 20).map(t => `<span>${esc(t)}</span>`).join('')}</div>` : ''}
                <div class="cb-defs">${sections}</div>
            </div>
        </div>
        ${state.zoomed && card.avatarUrl ? `<div class="cb-zoom-overlay" data-action="unzoom"><img src="${esc(card.fullAvatarUrl || card.avatarUrl)}" data-zoom-fallback="${esc(card.avatarUrl)}" alt="${esc(card.name)}" referrerpolicy="no-referrer"></div>` : ''}`;
}

/** restore: true scrolls to the top for a new detail page, 'restore' returns to the saved results position. */
function renderMain(scroll) {
    const main = root?.querySelector('.cb-main');
    if (!main) return;
    const p = provider();
    withFocus(() => {
        if (p.unavailable || needsPluginNotice()) main.innerHTML = noticeHtml(p);
        else if (state.selectedCard) main.innerHTML = detailHtml();
        else {
            main.innerHTML = toolbarHtml();
            renderResults();
        }
    });
    if (scroll === true) main.scrollTop = 0;
    else if (scroll === 'restore') {
        main.scrollTop = resultsScrollTop;
        requestAnimationFrame(() => { main.scrollTop = resultsScrollTop; });
    }
}

function renderModals() {
    const layer = root?.querySelector('.cb-modals');
    if (!layer) return;
    const p = provider();
    let html = '';
    const pending = state.pendingImport;
    if (pending) {
        const card = pending.card;
        let body;
        if (!pending.target) {
            body = `<div><p class="cb-strong">Where should this card live?</p><p class="cb-muted cb-small-text">The same downloaded card can become an AI character or one of your personas.</p></div>
                <div class="cb-target-grid">
                    <button type="button" class="menu_button cb-target" data-action="import-target" data-target="character">
                        <span class="cb-target-icon"><i class="fa-solid fa-users"></i></span>
                        <span><b>Import as Character</b><small>Add this card to Characters so the AI can play or speak as them.</small></span>
                    </button>
                    <button type="button" class="menu_button cb-target" data-action="import-target" data-target="persona">
                        <span class="cb-target-icon"><i class="fa-solid fa-masks-theater"></i></span>
                        <span><b>Import as Persona</b><small>Add this card to Personas so it can represent you in chats.</small></span>
                    </button>
                </div>`;
        } else if (!pending.prepared) {
            body = '<div class="cb-center"><i class="fa-solid fa-spinner fa-spin"></i> Preparing card…</div>';
        } else {
            const count = countLorebookEntries(pending.prepared.embeddedLorebook);
            body = `<div class="cb-lore-box"><i class="fa-solid fa-book-open"></i><div><p class="cb-strong">Embedded lorebook found</p>
                    <p class="cb-small-text">This card includes ${count} lorebook ${count === 1 ? 'entry' : 'entries'}. Import ${count === 1 ? 'it' : 'them'} as a standalone World Info book and link it too?</p></div></div>
                <div class="cb-modal-actions">
                    <button type="button" class="menu_button" data-action="import-back" ${state.importing ? 'disabled' : ''}><i class="fa-solid fa-arrow-left"></i> Back</button>
                    <span class="cb-flex1"></span>
                    <button type="button" class="menu_button" data-action="finish-import" data-lorebook="0" ${state.importing ? 'disabled' : ''}>No Import</button>
                    <button type="button" class="menu_button cb-primary" data-action="finish-import" data-lorebook="1" ${state.importing ? 'disabled' : ''}><i class="fa-solid ${state.importing ? 'fa-spinner fa-spin' : 'fa-book-open'}"></i> Import Lorebook</button>
                </div>`;
        }
        html += `<div class="cb-modal-backdrop" data-action="close-import"><div class="cb-modal" data-stop>
            <div class="cb-modal-head"><h3>Import Card</h3><button type="button" class="menu_button cb-small" data-action="close-import" ${state.importing ? 'disabled' : ''}><i class="fa-solid fa-xmark"></i></button></div>
            <div class="cb-modal-body">
                <div class="cb-import-card"><div class="cb-import-avatar">${avatarHtml(card.avatarUrl, card.name)}</div>
                    <div><p class="cb-strong">${esc(card.name)}</p><p class="cb-muted cb-small-text">${card.creator ? `by ${esc(card.creator)}` : esc(p.name)}</p></div></div>
                ${body}
            </div></div></div>`;
    }
    if (state.showLoginModal) {
        html += `<div class="cb-modal-backdrop" data-action="close-login"><div class="cb-modal" data-stop>
            <div class="cb-modal-head"><h3><i class="fa-solid fa-key cb-amber-text"></i> Pygmalion Authentication</h3><button type="button" class="menu_button cb-small" data-action="close-login"><i class="fa-solid fa-xmark"></i></button></div>
            <div class="cb-modal-body">
                <div class="cb-info-box cb-green">✅ <b>Browsing and downloading public characters works without logging in!</b></div>
                <div class="cb-info-box cb-amber">🔑 <b>Optional:</b> Paste your auth token to enable NSFW content and access authenticated character data.</div>
                <label class="cb-small-text cb-muted" for="cb-pyg-token">Auth Token</label>
                <input id="cb-pyg-token" type="password" autocomplete="off" spellcheck="false" class="text_pole cb-mono" data-focus-key="pyg-token" ${state.pygLoggedIn || state.loginLoading ? 'disabled' : ''} placeholder="Paste your Pygmalion auth token here">
                <p class="cb-small-text cb-muted">This is your Pygmalion account login. The server plugin keeps it in memory until SillyTavern restarts or you log out. To fully sign out, also log out on pygmalion.chat.</p>
                <details><summary>▸ ❓ How to get your auth token</summary><div class="cb-help">
                    <p>1. Go to <a href="https://pygmalion.chat" target="_blank" rel="noopener noreferrer">pygmalion.chat</a> and log in</p>
                    <p>2. Open DevTools (F12) → <b>Application</b> tab → <b>Local Storage</b></p>
                    <p>3. Find the entry named <code>authn</code></p>
                    <p>4. Copy its <b>Value</b> (a long string, ~705 characters) and paste it above</p></div></details>
                ${state.pygLoggedIn ? '<div class="cb-green-text"><i class="fa-solid fa-circle-check"></i> Token active, NSFW content enabled</div>' : ''}
                <div class="cb-modal-actions">
                    ${state.pygLoggedIn
        ? '<button type="button" class="menu_button" data-action="pyg-logout"><i class="fa-solid fa-right-from-bracket"></i> Log Out</button>'
        : `<button type="button" class="menu_button cb-primary" data-action="pyg-login" ${state.loginLoading ? 'disabled' : ''}><i class="fa-solid ${state.loginLoading ? 'fa-spinner fa-spin' : 'fa-key'}"></i> Save & Connect</button>`}
                    <a class="menu_button" href="https://pygmalion.chat" target="_blank" rel="noopener noreferrer"><i class="fa-solid fa-arrow-up-right-from-square"></i> Website</a>
                </div>
            </div></div></div>`;
    }
    if (state.pendingDatacatSwitch) {
        html += `<div class="cb-modal-backdrop" data-action="cancel-datacat"><div class="cb-modal" data-stop>
            <div class="cb-modal-head"><h3><span class="cb-amber-text">⚠️</span> DataCat is NSFW only</h3><button type="button" class="menu_button cb-small" data-action="cancel-datacat"><i class="fa-solid fa-xmark"></i></button></div>
            <div class="cb-modal-body"><p>Every character on DataCat is tagged NSFW there, so the NSFW filter stays on for this source.</p>
                <div class="cb-modal-actions">
                    <button type="button" class="menu_button cb-primary cb-flex1" data-action="confirm-datacat">Continue to DataCat</button>
                    <button type="button" class="menu_button cb-flex1" data-action="cancel-datacat">Don't continue to DataCat</button>
                </div></div></div></div>`;
    }
    withFocus(() => { layer.innerHTML = html; });
}

// ════════════════════════════════════════════════
// Events
// ════════════════════════════════════════════════

function onClick(event) {
    const target = event.target.closest('[data-action]');
    if (!target || !root.contains(target)) return;
    // clicks inside a modal box never reach its backdrop's close action
    if (target.classList.contains('cb-modal-backdrop') && event.target.closest('[data-stop]')) return;
    const action = target.dataset.action;
    const tag = target.dataset.tag;
    switch (action) {
        case 'close': return closeBrowser();
        case 'toggle-source': state.sourceOpen = !state.sourceOpen; return renderHeader();
        case 'close-source': state.sourceOpen = false; return renderHeader();
        case 'switch-source': return switchProvider(target.dataset.id);
        case 'toggle-tags': state.showTagPanel = !state.showTagPanel; return render();
        case 'clear-tags': Object.assign(state, { includeTags: [], excludeTags: [], page: 1 }); render(); return scheduleSearch();
        case 'toggle-include':
            state.includeTags = state.includeTags.includes(tag) ? state.includeTags.filter(t => t !== tag) : [...state.includeTags, tag];
            state.excludeTags = state.excludeTags.filter(t => t !== tag);
            state.page = 1;
            render();
            return scheduleSearch();
        case 'toggle-exclude':
            state.excludeTags = state.excludeTags.includes(tag) ? state.excludeTags.filter(t => t !== tag) : [...state.excludeTags, tag];
            state.includeTags = state.includeTags.filter(t => t !== tag);
            state.page = 1;
            render();
            return scheduleSearch();
        case 'add-custom-include': return addCustomTag(true);
        case 'add-custom-exclude': return addCustomTag(false);
        case 'toggle-filters': state.showFiltersPanel = !state.showFiltersPanel; return renderMain(false);
        case 'clear-query': state.query = ''; state.page = 1; renderMain(false); return scheduleSearch();
        case 'refresh': return doSearch();
        case 'nsfw-label': {
            if (event.target.matches('input')) return;
            const p = provider();
            const greyed = p.nsfwMode === 'login' && state.sourceId === 'pygmalion' && state.pygLoggedIn;
            if (greyed || effectiveNsfwAvailable()) return;
            event.preventDefault();
            if (state.sourceId === 'wyvern') toastr.info('Use the "🔞 Popular NSFW" sort option to browse NSFW content on Wyvern.');
            else if (p.nsfwMode === 'login') {
                state.showLoginModal = true;
                renderModals();
            }
            return;
        }
        case 'open-login': state.showLoginModal = true; return renderModals();
        case 'close-login': state.showLoginModal = false; return renderModals();
        case 'pyg-login': return pygmalionSetToken(root.querySelector('#cb-pyg-token')?.value ?? '');
        case 'pyg-logout': return pygmalionLogout();
        case 'prev-page': state.page = Math.max(1, state.page - 1); return scheduleSearch();
        case 'next-page': state.page += 1; return scheduleSearch();
        case 'open-card': return openDetail(state.results[Number(target.dataset.index)]);
        case 'back': return closeDetail();
        case 'zoom': state.zoomed = true; return renderMain(false);
        case 'unzoom': state.zoomed = false; return renderMain(false);
        case 'import': state.sourceOpen = false; state.pendingImport = { card: state.selectedCard }; return renderModals();
        case 'import-target': return chooseImportTarget(target.dataset.target);
        case 'import-back': state.pendingImport = { card: state.pendingImport.card }; return renderModals();
        case 'finish-import': return finishImport(target.dataset.lorebook === '1');
        case 'close-import': if (!state.importing) state.pendingImport = null; return renderModals();
        case 'download-png': return downloadPng();
        case 'confirm-datacat': state.datacatNsfwAcked = true; state.pendingDatacatSwitch = false; return performSwitch('datacat');
        case 'cancel-datacat': state.pendingDatacatSwitch = false; return renderModals();
        case 'st-import': closeBrowser(); return $('#character_import_button').trigger('click');
    }
}

function addCustomTag(include) {
    const custom = state.tagSearch.trim().toLowerCase();
    if (custom.length < 2) return;
    if (include && !state.includeTags.includes(custom)) {
        state.includeTags = [...state.includeTags, custom];
        state.excludeTags = state.excludeTags.filter(t => t !== custom);
    } else if (!include && !state.excludeTags.includes(custom)) {
        state.excludeTags = [...state.excludeTags, custom];
        state.includeTags = state.includeTags.filter(t => t !== custom);
    } else return;
    state.tagSearch = '';
    state.page = 1;
    render();
    scheduleSearch();
}

function onInput(event) {
    const el = event.target;
    switch (el.dataset.input) {
        case 'query':
            state.query = el.value;
            state.page = 1;
            // only the clear button depends on the text; the input itself must not be rebuilt while typing
            if (!!el.parentElement.querySelector('.cb-clear') !== !!state.query) renderMain(false);
            return scheduleSearch();
        case 'tag-search':
            state.tagSearch = el.value;
            return withFocus(renderTagPanel);
        case 'min-tokens': state.minTokens = el.value; state.page = 1; return scheduleSearch();
        case 'max-tokens': state.maxTokens = el.value; state.page = 1; return scheduleSearch();
    }
}

function onChange(event) {
    const el = event.target;
    switch (el.dataset.input) {
        case 'sort': state.sort = el.value; state.page = 1; return scheduleSearch();
        case 'sort-dir': state.sortAsc = el.value === 'asc'; state.page = 1; return scheduleSearch();
        case 'nsfw':
            if (effectiveNsfwAvailable()) {
                setNsfw(el.checked);
                state.page = 1;
                scheduleSearch();
            }
            return;
        case 'feature': state.features = { ...state.features, [el.dataset.key]: el.checked }; state.page = 1; renderMain(false); return scheduleSearch();
        case 'extra': state.extraToggles = { ...state.extraToggles, [el.dataset.key]: el.checked }; state.page = 1; renderMain(false); return scheduleSearch();
        case 'page': state.page = Number(el.value); return scheduleSearch();
        case 'tag-mode': state.tagImportMode = el.value; return renderMain(false);
    }
}

function onKeyDown(event) {
    if (event.key === 'Enter' && event.target.dataset.input === 'tag-search') {
        event.preventDefault();
        addCustomTag(true);
    } else if (event.key === 'Enter' && event.target.id === 'cb-pyg-token') {
        event.preventDefault();
        pygmalionSetToken(event.target.value);
    } else if (event.key === 'Escape' && root) {
        // SillyTavern closes its own panels on Escape too; the browser on top handles it first
        event.stopPropagation();
        event.preventDefault();
        if (state.zoomed) {
            state.zoomed = false;
            renderMain(false);
        } else if (state.showLoginModal || state.pendingDatacatSwitch || (state.pendingImport && !state.importing)) {
            Object.assign(state, { showLoginModal: false, pendingDatacatSwitch: false, pendingImport: state.importing ? state.pendingImport : null });
            renderModals();
        } else if (state.sourceOpen) {
            state.sourceOpen = false;
            renderHeader();
        } else if (state.selectedCard) closeDetail();
        else closeBrowser();
    }
}

function onImageError(event) {
    const img = event.target;
    if (!(img instanceof HTMLImageElement)) return;
    if (img.dataset.zoomFallback && img.src !== new URL(img.dataset.zoomFallback, location.href).href) {
        img.src = img.dataset.zoomFallback;
        return;
    }
    if (img.hasAttribute('data-fallback')) {
        const fallback = document.createElement('div');
        fallback.className = 'cb-avatar-fallback';
        fallback.innerHTML = '<i class="fa-solid fa-hashtag"></i>';
        img.replaceWith(fallback);
    }
}

// ════════════════════════════════════════════════
// Open, close and the entry points
// ════════════════════════════════════════════════

async function probePlugin() {
    try {
        const res = await fetch(`${PLUGIN}/health`, { headers: getRequestHeaders() });
        pluginAvailable = res.ok && (await res.json())?.ok === true;
    } catch {
        pluginAvailable = false;
    }
}

async function syncPygmalionSession() {
    if (!pluginAvailable) return;
    try {
        const d = await (await pluginFetch('/pygmalion/session')).json();
        if (!d?.active && state.pygLoggedIn) {
            setPygLoggedIn(false);
            toastr.info('Pygmalion session expired, please log in again.');
        } else if (d?.active) setPygLoggedIn(true);
    } catch { /* offline */ }
}

async function openBrowser() {
    if (root) return;
    root = document.createElement('div');
    root.id = 'cardbrowser_root';
    root.innerHTML = '<header class="cb-header"></header><div class="cb-body"><aside class="cb-tags" hidden></aside><div class="cb-main"></div></div><div class="cb-modals"></div>';
    document.body.appendChild(root);
    root.addEventListener('click', onClick);
    root.addEventListener('input', onInput);
    root.addEventListener('change', onChange);
    root.addEventListener('keydown', onKeyDown);
    document.addEventListener('keydown', onDocumentKeyDown, true);
    root.addEventListener('error', onImageError, true);
    await probePlugin();
    await syncPygmalionSession();
    render();
    if (state.results.length === 0) scheduleSearch();
}

function onDocumentKeyDown(event) {
    if (event.key === 'Escape' && root && !root.contains(event.target)) onKeyDown(event);
}

function closeBrowser() {
    clearTimeout(searchTimer);
    document.removeEventListener('keydown', onDocumentKeyDown, true);
    root?.remove();
    root = null;
    state.sourceOpen = false;
}

jQuery(() => {
    const button = $('<div id="cardbrowser_button" title="Browse character cards online" class="menu_button fa-solid fa-compass"></div>');
    button.on('click', openBrowser);
    $('#external_import_button').after(button);
    const wand = $(`<div id="cardbrowser_wand" class="list-group-item flex-container flexGap5" title="Browse character cards online">
        <div class="fa-solid fa-compass extensionsMenuExtensionButton"></div><span>Card Browser</span></div>`);
    wand.on('click', openBrowser);
    $('#extensionsMenu').append(wand);
});
