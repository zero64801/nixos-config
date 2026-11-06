import { BaseText } from "@components/BaseText";
import { useTimer } from "@utils/react";
import { Message, RenderModalProps } from "@vencord/discord-types";
import { ChannelStore, Checkbox, GuildMemberStore, Modal, openModal, TextInput, UserStore, useState } from "@webpack/common";

import { settings } from "./settings";
import { averageWait, getRun, isRunning, isSelected, remaining, Run, selectedMessages, startRun, stopRun, toggle, useBulkDelete } from "./store";

type RowKind = "selected" | "waiting" | "current" | "deleted" | "gone" | "failed" | "skipped";

function duration(ms: number) {
    const seconds = Math.max(0, Math.ceil(ms / 1000));
    return seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
}

function parseWhole(text: string, max = Infinity) {
    const value = /^\d+$/.test(text.trim()) ? Number(text) : null;
    return value != null && value <= max ? value : null;
}

function plural(count: number, noun: string) {
    return `${count} ${noun}${count === 1 ? "" : "s"}`;
}

function channelLabel(channelId: string) {
    const channel = ChannelStore.getChannel(channelId);
    if (!channel) return "Unknown channel";
    if (channel.guild_id) return `#${channel.name}`;

    return channel.name || `DM with ${channel.recipients.map((id: string) => UserStore.getUser(id)?.username ?? id).join(", ")}`;
}

function placeLabel(messages: Message[]) {
    const channels = new Set(messages.map(message => message.channel_id));
    return channels.size === 1 ? channelLabel([...channels][0]) : `${channels.size} channels`;
}

function authorName({ author, channel_id }: Message) {
    const guildId = ChannelStore.getChannel(channel_id)?.guild_id;
    return (guildId && GuildMemberStore.getNick(guildId, author.id)) || author.globalName || author.username;
}

function preview(message: Message) {
    const text = message.content
        .replace(/<a?:(\w+):\d+>/g, ":$1:")
        .replace(/<@!?(\d+)>/g, (raw, id) => {
            const user = UserStore.getUser(id);
            return user ? `@${user.username}` : raw;
        })
        .replace(/<#(\d+)>/g, (raw, id) => {
            const channel = ChannelStore.getChannel(id);
            return channel?.name ? `#${channel.name}` : raw;
        })
        .replace(/\s+/g, " ")
        .trim();
    if (text) return text;

    if (message.attachments.length) return plural(message.attachments.length, "attachment");
    if (message.messageSnapshots?.length) return "Forwarded message";
    if (message.stickerItems?.length) return "Sticker";
    return message.embeds.length ? "Embed" : "No text";
}

function Row({ message, kind, reason, onRemove }: { message: Message; kind: RowKind; reason?: string; onRemove?(): void; }) {
    const time = new Date(message.timestamp).toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });

    return (
        <div className={`vc-bulk-delete-row vc-bulk-delete-row-${kind}`}>
            <span className="vc-bulk-delete-mark" />
            <div className="vc-bulk-delete-row-body">
                <div className="vc-bulk-delete-row-meta">
                    <BaseText tag="span" size="sm" weight="semibold">{authorName(message)}</BaseText>
                    <BaseText tag="span" size="xs" defaultColor={false} className="vc-bulk-delete-row-time">{time}</BaseText>
                </div>
                <BaseText size="sm" defaultColor={false} className="vc-bulk-delete-row-text">{preview(message)}</BaseText>
                {reason && <BaseText size="xs" defaultColor={false} className="vc-bulk-delete-row-reason">{reason}</BaseText>}
            </div>
            {onRemove && (
                <button className="vc-bulk-delete-row-remove" aria-label="Deselect" onClick={onRemove}>×</button>
            )}
        </div>
    );
}

function ConfirmView({ onStart, ...props }: RenderModalProps & { onStart(): void; }) {
    const [delay, setDelay] = useState(String(settings.store.delay));
    const [variation, setVariation] = useState(String(settings.store.variation));
    const [breaks, setBreaks] = useState(settings.store.breaks);

    const messages = selectedMessages();
    const delayMs = parseWhole(delay);
    const variationPct = parseWhole(variation, 100);
    const pace = delayMs != null && variationPct != null ? { delay: delayMs, variation: variationPct, breaks } : null;
    const me = UserStore.getCurrentUser()?.id;
    const others = messages.filter(message => message.author.id !== me).length;

    function start() {
        if (!pace) return;

        settings.store.delay = pace.delay;
        settings.store.variation = pace.variation;
        settings.store.breaks = pace.breaks;
        onStart();
        void startRun(pace);
    }

    return (
        <Modal
            {...props}
            size="md"
            title={`Delete ${plural(messages.length, "message")}`}
            subtitle={messages.length ? placeLabel(messages) : "Nothing is selected"}
            notice={others ? { type: "critical", message: `${plural(others, "message")} here ${others === 1 ? "is" : "are"} from someone else.` } : undefined}
            actionBarInput={
                <Checkbox value={breaks} onChange={(_: unknown, value: boolean) => setBreaks(value)} size={20}>
                    <BaseText tag="span" size="sm">Take short breaks</BaseText>
                </Checkbox>
            }
            actions={[
                { text: "Cancel", variant: "secondary", onClick: props.onClose },
                {
                    text: `Delete ${messages.length}`,
                    variant: "critical-primary",
                    disabled: !messages.length || !pace,
                    onClick: start
                }
            ]}
        >
            <div className="vc-bulk-delete-list">
                {messages.map(message => (
                    <Row key={message.id} message={message} kind="selected" onRemove={() => toggle(message)} />
                ))}
            </div>
            <div className="vc-bulk-delete-pace">
                <label className="vc-bulk-delete-pace-field">
                    <BaseText tag="span" size="xs" weight="semibold">Typical delay (ms)</BaseText>
                    <TextInput type="number" min={0} value={delay} onChange={setDelay} error={delayMs == null ? "Whole milliseconds" : undefined} />
                </label>
                <label className="vc-bulk-delete-pace-field">
                    <BaseText tag="span" size="xs" weight="semibold">Variation (%)</BaseText>
                    <TextInput type="number" min={0} max={100} value={variation} onChange={setVariation} error={variationPct == null ? "0 to 100" : undefined} />
                </label>
            </div>
            {pace && messages.length > 1 && (
                <BaseText size="sm" defaultColor={false} className="vc-bulk-delete-hint">
                    Takes about {duration((messages.length - 1) * averageWait(pace))}
                </BaseText>
            )}
        </Modal>
    );
}

function ProgressView({ run, ...props }: RenderModalProps & { run: Run; }) {
    // Keeps the countdowns moving between deletions.
    useTimer({ interval: 500 });

    const total = run.messages.length;
    const left = remaining(run);
    const failed = [...run.results.values()].filter(result => result.outcome === "failed").length;
    const deleted = run.results.size - failed;

    let status: string;
    if (run.finished) {
        status = `Deleted ${deleted} of ${total}`;
        if (failed) status += `, ${failed} failed and stay selected`;
    } else if (run.stopped) {
        status = "Stopping after this message";
    } else if (run.rateLimitedUntil) {
        status = `Discord asked to slow down, retrying in ${duration(run.rateLimitedUntil - Date.now())}`;
    } else if (run.restingUntil && run.restingUntil > Date.now()) {
        status = `Taking a short break, back in ${duration(run.restingUntil - Date.now())}`;
    } else {
        status = `Deleting ${Math.min(total, total - left + 1)} of ${total}, about ${duration((left - 1) * averageWait(run.pace))} left`;
    }

    function kindOf(message: Message): RowKind {
        const result = run.results.get(message.id);
        if (result) return result.outcome;
        if (run.current === message.id) return "current";
        return run.finished || !isSelected(message.id) ? "skipped" : "waiting";
    }

    return (
        <Modal
            {...props}
            size="md"
            title={run.finished ? (run.stopped ? "Stopped" : "Done") : "Deleting messages"}
            subtitle={placeLabel(run.messages)}
            actions={run.finished
                ? [{ text: "Close", variant: "primary", onClick: props.onClose }]
                : [
                    { text: "Hide", variant: "secondary", onClick: props.onClose },
                    { text: "Stop", variant: "critical-primary", disabled: run.stopped, onClick: stopRun }
                ]}
        >
            <div className={run.finished ? "vc-bulk-delete-progress" : "vc-bulk-delete-progress vc-bulk-delete-progress-running"}>
                <div className="vc-bulk-delete-progress-fill" style={{ width: `${(run.results.size / total) * 100}%` }} />
            </div>
            <BaseText size="sm" defaultColor={false} className="vc-bulk-delete-hint">{status}</BaseText>
            <div className="vc-bulk-delete-list">
                {run.messages.map(message => (
                    <Row key={message.id} message={message} kind={kindOf(message)} reason={run.results.get(message.id)?.reason} />
                ))}
            </div>
        </Modal>
    );
}

function DeleteModal(props: RenderModalProps) {
    useBulkDelete();

    const [watching, setWatching] = useState(isRunning());
    const run = getRun();

    return watching && run
        ? <ProgressView {...props} run={run} />
        : <ConfirmView {...props} onStart={() => setWatching(true)} />;
}

export function openDeleteModal() {
    openModal(props => <DeleteModal {...props} />);
}
