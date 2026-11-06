import { updateMessage } from "@api/MessageUpdater";
import { useForceUpdater } from "@utils/react";
import { Channel, Message } from "@vencord/discord-types";
import { MessageFlags } from "@vencord/discord-types/enums";
import { ChannelStore, Constants, MessageStore, MessageTypeSets, PermissionsBits, PermissionStore, RestAPI, useEffect, UserStore } from "@webpack/common";

export type Outcome = "deleted" | "gone" | "failed";

export interface Result {
    outcome: Outcome;
    reason?: string;
}

export interface Pace {
    delay: number;
    variation: number;
    breaks: boolean;
}

export interface Run {
    messages: Message[];
    results: Map<string, Result>;
    pace: Pace;
    current?: string;
    restingUntil?: number;
    rateLimitedUntil?: number;
    stopped: boolean;
    finished: boolean;
}

const BREAK_CHANCE = 0.08;
const BREAK_MIN = 2;
const BREAK_MAX = 4;

const selection = new Map<string, Message>();
const listeners = new Set<() => void>();
let anchor: Message | undefined;
// The selection as it was when a drag began, so the swept range can shrink again.
let dragBase: Map<string, Message> | undefined;
let run: Run | undefined;
let wake: (() => void) | undefined;

function notify() {
    listeners.forEach(listener => listener());
}

function refresh(messages: Iterable<Message>) {
    for (const message of messages) updateMessage(message.channel_id, message.id);
    notify();
}

export function useBulkDelete() {
    const update = useForceUpdater();
    useEffect(() => {
        listeners.add(update);
        return () => void listeners.delete(update);
    }, []);
}

export function canDelete(message: Message, channel: Channel | undefined = ChannelStore.getChannel(message.channel_id)) {
    // MessageLogger keeps deleted messages in the store and flags them.
    if (message.deleted || message.state !== "SENT") return false;
    if (MessageTypeSets.UNDELETABLE.has(message.type) || message.hasFlag(MessageFlags.EPHEMERAL)) return false;

    return message.author.id === UserStore.getCurrentUser()?.id
        || (channel != null && PermissionStore.can(PermissionsBits.MANAGE_MESSAGES, channel));
}

export const isSelected = (id: string) => selection.has(id);
export const selectedCount = () => selection.size;

// Snowflakes grow with time, so this is chat order.
const byAge = (a: Message, b: Message) => BigInt(a.id) < BigInt(b.id) ? -1 : 1;

export function selectedMessages() {
    return [...selection.values()].sort(byAge);
}

export function toggle(message: Message) {
    if (!selection.delete(message.id)) selection.set(message.id, message);
    anchor = message;
    refresh([message]);
}

function deletableBetween(from: Message, to: Message, channel: Channel | undefined = ChannelStore.getChannel(to.channel_id)) {
    const loaded: Message[] = [];
    MessageStore.getMessages(to.channel_id).forEach((message: Message) => {
        loaded.push(message);
    });

    const start = loaded.findIndex(message => message.id === from.id);
    const end = loaded.findIndex(message => message.id === to.id);
    if (start === -1 || end === -1) return null;

    return loaded
        .slice(Math.min(start, end), Math.max(start, end) + 1)
        .filter(message => canDelete(message, channel));
}

export function selectRange(target: Message, channel: Channel) {
    const range = anchor && deletableBetween(anchor, target, channel);
    if (!range) return toggle(target);

    for (const message of range) selection.set(message.id, message);
    anchor = target;
    refresh(range);
}

export function beginDrag() {
    dragBase = new Map(selection);
}

export function dragTo(from: Message, to: Message, erase: boolean) {
    if (!dragBase) return;

    const next = new Map(dragBase);
    for (const message of deletableBetween(from, to) ?? []) {
        if (erase) next.delete(message.id);
        else next.set(message.id, message);
    }

    const dropped = [...selection.values()].filter(message => !next.has(message.id));
    const added = [...next.values()].filter(message => !selection.has(message.id));
    for (const message of dropped) selection.delete(message.id);
    for (const message of added) selection.set(message.id, message);
    anchor = to;
    refresh([...dropped, ...added]);
}

export function endDrag() {
    dragBase = undefined;
}

export function deselect(ids: string[]) {
    const dropped = ids.flatMap(id => selection.get(id) ?? []);
    if (!dropped.length) return;

    for (const message of dropped) selection.delete(message.id);
    refresh(dropped);
}

export function keepChannel(channelId: string | null) {
    deselect([...selection.values()].filter(message => message.channel_id !== channelId).map(message => message.id));
}

export function clearSelection() {
    const dropped = [...selection.values()];
    selection.clear();
    anchor = undefined;
    refresh(dropped);
}

export const getRun = () => run;
export const isRunning = () => run != null && !run.finished;

export function remaining(current: Run) {
    return current.messages.filter(message => !current.results.has(message.id) && selection.has(message.id)).length;
}

// Prepended to Discord's own className, hence the trailing space.
export function rowClass(id: string) {
    if (!selection.has(id)) return "";
    if (run?.current === id) return "vc-bulk-delete-selected vc-bulk-delete-current ";
    if (run?.results.get(id)?.outcome === "failed") return "vc-bulk-delete-selected vc-bulk-delete-failed ";
    return "vc-bulk-delete-selected ";
}

function gaussian() {
    return Math.sqrt(-2 * Math.log(1 - Math.random())) * Math.cos(2 * Math.PI * Math.random());
}

// Human timing is right skewed: mostly near the usual pace, sometimes much slower, never much faster.
export function nextGap({ delay, variation }: Pace) {
    let gap: number;
    do {
        gap = delay * Math.exp(variation / 100 * gaussian());
    } while (gap < delay / 2);
    return gap;
}

export function nextBreak({ delay, breaks }: Pace) {
    return breaks && Math.random() < BREAK_CHANCE ? delay * (BREAK_MIN + (BREAK_MAX - BREAK_MIN) * Math.random()) : 0;
}

export function averageWait({ delay, variation, breaks }: Pace) {
    const spread = variation / 100;
    return delay * (Math.exp(spread * spread / 2) + (breaks ? BREAK_CHANCE * (BREAK_MIN + BREAK_MAX) / 2 : 0));
}

function sleepUntil(time: number) {
    return new Promise<void>(resolve => {
        const timer = setTimeout(done, Math.max(0, time - Date.now()));
        wake = done;

        function done() {
            clearTimeout(timer);
            wake = undefined;
            resolve();
        }
    });
}

async function remove(message: Message, current: Run): Promise<Result | undefined> {
    while (!current.stopped) {
        try {
            await RestAPI.del({ url: Constants.Endpoints.MESSAGE(message.channel_id, message.id) });
            return { outcome: "deleted" };
        } catch (err: any) {
            if (err?.status === 404) return { outcome: "gone" };
            if (err?.status !== 429) return { outcome: "failed", reason: err?.body?.message ?? (err?.status ? `HTTP ${err.status}` : String(err)) };

            // retry_after is in seconds.
            current.rateLimitedUntil = Date.now() + (Number(err.body?.retry_after) || 1) * 1000 + 250;
            notify();
            await sleepUntil(current.rateLimitedUntil);
            current.rateLimitedUntil = undefined;
        }
    }
}

export async function startRun(pace: Pace) {
    if (isRunning() || !selection.size) return;

    const previous = run;
    const current: Run = run = { messages: selectedMessages(), results: new Map(), pace, stopped: false, finished: false };
    // Drops the failed mark an earlier run left on these.
    refresh(current.messages.filter(message => previous?.results.get(message.id)?.outcome === "failed"));

    let next = 0;
    for (const message of current.messages) {
        if (current.stopped) break;
        await sleepUntil(next);
        if (current.stopped) break;
        // Deselected, or deleted somewhere else, since the run started.
        if (!selection.has(message.id)) continue;

        current.current = message.id;
        refresh([message]);
        const result = await remove(message, current);
        current.current = undefined;
        if (!result) break;

        current.results.set(message.id, result);
        if (result.outcome !== "failed") selection.delete(message.id);

        const pause = nextBreak(pace);
        next = Date.now() + nextGap(pace) + pause;
        current.restingUntil = pause ? next : undefined;
        refresh([message]);
    }

    current.finished = true;
    notify();
}

export function stopRun() {
    if (!run || run.finished) return;

    run.stopped = true;
    wake?.();
    notify();
}

export function reset() {
    stopRun();
    clearSelection();
}
