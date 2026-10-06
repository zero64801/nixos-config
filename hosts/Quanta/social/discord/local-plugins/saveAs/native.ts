import { IpcMainInvokeEvent, net } from "electron";

// Any renderer code can invoke this, so it only fetches attachments.
const CDN_HOSTS = new Set(["cdn.discordapp.com", "media.discordapp.net"]);

// net.fetch rather than Node's fetch, which would bypass the session's --proxy-server.
export async function download(_: IpcMainInvokeEvent, url: string) {
    const { protocol, hostname } = new URL(url);
    if (protocol !== "https:" || !CDN_HOSTS.has(hostname)) throw new Error(`Refusing to fetch from ${hostname}`);

    const res = await net.fetch(url);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return new Uint8Array(await res.arrayBuffer());
}
