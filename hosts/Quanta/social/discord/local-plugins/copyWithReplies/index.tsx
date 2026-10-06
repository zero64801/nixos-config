import { findGroupChildrenByChildId, NavContextMenuPatchCallback } from "@api/ContextMenu";
import { definePluginSettings } from "@api/Settings";
import { copyWithToast } from "@utils/discord";
import definePlugin, { OptionType } from "@utils/types";
import { Message } from "@vencord/discord-types";
import { MessageType } from "@vencord/discord-types/enums";
import { ChannelStore, ContextMenuApi, GuildMemberStore, GuildRoleStore, GuildStore, Menu, MessageStore, RestAPI, UserStore } from "@webpack/common";

type Attachment = { filename: string; url: string; };

type Author = { id: string; username: string; globalName?: string | null; };

type Post = {
    author: Author;
    content: string;
    forwarded?: string;
    attachments: Attachment[];
};

type Naming = {
    guildId?: string;
    author(user: Author): string;
    mention(id: string): string | undefined;
    attachment(file: Attachment): string;
    scrub(text: string): string;
};

// MessageLogger keeps deleted messages in the store and flags them.
type LoggedMessage = Message & { deleted?: boolean; };

const settings = definePluginSettings({
    anonymize: {
        type: OptionType.BOOLEAN,
        description: "Replace people with random names and leave out server names and attachment links",
        default: false
    }
});

const CHAT_TYPES = new Set([
    MessageType.DEFAULT,
    MessageType.REPLY,
    MessageType.CHAT_INPUT_COMMAND,
    MessageType.CONTEXT_MENU_COMMAND
]);

const ADJECTIVES = ["Amber", "Azure", "Brisk", "Calm", "Clever", "Coral", "Dusky", "Gentle", "Golden", "Hazel", "Ivory", "Jade", "Lucky", "Misty", "Quiet", "Rusty", "Silver", "Sunny", "Swift", "Velvet"];
const ANIMALS = ["Badger", "Crane", "Falcon", "Ferret", "Fox", "Heron", "Lynx", "Marten", "Otter", "Owl", "Panda", "Raven", "Robin", "Seal", "Sparrow", "Stoat", "Tiger", "Turtle", "Walrus", "Wolf"];

// Kept until Discord restarts so separate copies of one conversation agree on who is who.
const pseudonyms = new Map<string, string>();

function pseudonym(userId: string) {
    let name = pseudonyms.get(userId);
    if (name) return name;

    const taken = new Set(pseudonyms.values());
    const free = ADJECTIVES.flatMap(a => ANIMALS.map(b => `${a} ${b}`)).filter(n => !taken.has(n));
    name = free.length ? free[Math.floor(Math.random() * free.length)] : `User ${pseudonyms.size + 1}`;
    pseudonyms.set(userId, name);
    return name;
}

function pad(n: number) {
    return String(n).padStart(2, "0");
}

function formatTime(date: Date) {
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function quote(text: string) {
    return text.split("\n").map(line => `> ${line}`).join("\n");
}

function escapeRegExp(text: string) {
    return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function realNaming(guildId?: string): Naming {
    return {
        guildId,
        author(user) {
            const name = (guildId && GuildMemberStore.getNick(guildId, user.id)) || user.globalName || user.username;
            return name === user.username ? user.username : `${name} (@${user.username})`;
        },
        mention(id) {
            const user = UserStore.getUser(id);
            return user && `@${user.username}`;
        },
        attachment: ({ filename, url }) => `[attachment: ${filename} ${url}]`,
        scrub: text => text
    };
}

function anonymousNaming(participants: Author[], guildId?: string): Naming {
    const names = new Map<string, string>();
    for (const user of participants) {
        for (const name of [user.username, user.globalName, guildId && GuildMemberStore.getNick(guildId, user.id)]) {
            if (name && name.length >= 2 && !names.has(name)) names.set(name, pseudonym(user.id));
        }
    }

    // One pass with a group per name, so a pseudonym already written in is never matched by a later name.
    const entries = [...names].sort(([a], [b]) => b.length - a.length);
    const pattern = entries.length
        ? new RegExp(`(?<![\\p{L}\\p{N}])(?:${entries.map(([name]) => `(${escapeRegExp(name)})`).join("|")})(?![\\p{L}\\p{N}])`, "giu")
        : null;

    return {
        guildId,
        author: user => pseudonym(user.id),
        mention: id => `@${pseudonym(id)}`,
        attachment: ({ filename }) => `[attachment: ${filename}]`,
        scrub: text => pattern
            ? text.replace(pattern, (...groups) => entries[groups.slice(1).findIndex(g => g !== undefined)][1])
            : text
    };
}

function resolveMarkup(content: string, naming: Naming) {
    return content
        .replace(/<@!?(\d+)>/g, (raw, id) => naming.mention(id) ?? raw)
        .replace(/<@&(\d+)>/g, (raw, id) => {
            const role = naming.guildId && GuildRoleStore.getRole(naming.guildId, id);
            return role ? `@${role.name}` : raw;
        })
        .replace(/<#(\d+)>/g, (raw, id) => {
            const channel = ChannelStore.getChannel(id);
            return channel?.name ? `#${channel.name}` : raw;
        })
        .replace(/<a?:(\w+):\d+>/g, ":$1:")
        .replace(/<t:(-?\d+)(?::[tTdDfFR])?>/g, (_, seconds) => formatTime(new Date(Number(seconds) * 1000)));
}

function renderBody(post: Post, naming: Naming) {
    const lines = [resolveMarkup(post.content, naming)];
    if (post.forwarded) lines.push("[forwarded]", quote(resolveMarkup(post.forwarded, naming)));
    for (const file of post.attachments) lines.push(naming.attachment(file));
    return naming.scrub(lines.filter(Boolean).join("\n"));
}

function postFromRecord(msg: Message): Post {
    return {
        author: msg.author,
        content: msg.content,
        forwarded: msg.messageSnapshots?.[0]?.message.content,
        attachments: [...msg.attachments, ...(msg.messageSnapshots?.[0]?.message.attachments ?? [])]
    };
}

async function fetchPost(channelId: string, messageId: string): Promise<Post | null> {
    const cached = MessageStore.getMessage(channelId, messageId);
    if (cached) return postFromRecord(cached);

    try {
        // User accounts cannot GET a single message, so ask for the one around it.
        const res = await RestAPI.get({
            url: `/channels/${channelId}/messages`,
            query: { limit: 1, around: messageId },
            retries: 2
        });
        const json = res?.body?.[0];
        if (json?.id !== messageId) return null;

        return {
            author: { id: json.author.id, username: json.author.username, globalName: json.author.global_name },
            content: json.content,
            forwarded: json.message_snapshots?.[0]?.message.content,
            attachments: [...(json.attachments ?? []), ...(json.message_snapshots?.[0]?.message.attachments ?? [])]
        };
    } catch {
        return null;
    }
}

function participantsOf(posts: Post[]) {
    const users = new Map<string, Author>();
    const current = UserStore.getCurrentUser();
    if (current) users.set(current.id, current);

    for (const post of posts) {
        users.set(post.author.id, post.author);
        for (const [, id] of `${post.content}\n${post.forwarded ?? ""}`.matchAll(/<@!?(\d+)>/g)) {
            const user = UserStore.getUser(id);
            if (user) users.set(id, user);
        }
    }
    return [...users.values()];
}

function channelLabel(channelId: string) {
    const channel = ChannelStore.getChannel(channelId);
    if (!channel) return "Discord messages";
    if (channel.guild_id) return `Discord #${channel.name} in ${GuildStore.getGuild(channel.guild_id)?.name}`;

    const recipients = channel.recipients.map((id: string) => UserStore.getUser(id)?.username ?? id).join(", ");
    return channel.name ? `Discord group DM "${channel.name}" with ${recipients}` : `Discord DM with ${recipients}`;
}

async function formatConversation(channelId: string, messages: LoggedMessage[], anonymize: boolean) {
    const guildId = ChannelStore.getChannel(channelId)?.guild_id;
    const numbers = new Map(messages.map((msg, i) => [msg.id, i + 1]));
    const posts = messages.map(postFromRecord);

    // A number points inside the copy, a post is quoted, null could not be loaded.
    const replies: (number | Post | null | undefined)[] = [];
    for (const msg of messages) {
        const ref = msg.type === MessageType.REPLY ? msg.messageReference : undefined;
        replies.push(ref && (numbers.get(ref.message_id) ?? await fetchPost(ref.channel_id, ref.message_id)));
    }

    const quoted = replies.filter((reply): reply is Post => typeof reply === "object" && reply !== null);
    const naming = anonymize
        ? anonymousNaming(participantsOf([...posts, ...quoted]), guildId)
        : realNaming(guildId);

    const blocks = [anonymize ? "Discord conversation" : channelLabel(channelId)];
    for (const [i, msg] of messages.entries()) {
        let header = `[${i + 1}] ${naming.author(msg.author)} ${formatTime(new Date(msg.timestamp))}`;
        if (msg.deleted) header += " (deleted)";

        let replied = "";
        const reply = replies[i];
        if (typeof reply === "number") {
            header += `, replying to [${reply}]`;
        } else if (reply) {
            header += `, replying to ${naming.author(reply.author)}:`;
            replied = quote(renderBody(reply, naming));
        } else if (reply === null) {
            header += ", replying to a message that could not be loaded";
        }

        blocks.push([header, replied, renderBody(posts[i], naming)].filter(Boolean).join("\n"));
    }

    return blocks.join("\n\n");
}

function messagesFrom(start: Message) {
    const result: Message[] = [];
    let started = false;

    MessageStore.getMessages(start.channel_id).forEach(msg => {
        started ||= msg.id === start.id;
        if (started && CHAT_TYPES.has(msg.type)) result.push(msg);
    });

    // Search results and pinned popouts can show a message whose channel is not loaded.
    return result.length ? result : [start];
}

function selectedMessages(channelId: string) {
    const selection = document.getSelection();
    if (!selection?.rangeCount || selection.isCollapsed) return [];

    // intersectsNode rather than containsNode, which misses a selection lying entirely inside one message.
    const range = selection.getRangeAt(0);
    const prefix = `chat-messages-${channelId}-`;
    const ids = new Set<string>();
    document.querySelectorAll(`[id^="${prefix}"]`).forEach(el => {
        if (range.intersectsNode(el)) ids.add(el.id.slice(prefix.length));
    });

    const result: Message[] = [];
    MessageStore.getMessages(channelId).forEach(msg => {
        if (ids.has(msg.id) && CHAT_TYPES.has(msg.type)) result.push(msg);
    });
    return result;
}

async function copyMessages(channelId: string, messages: Message[]) {
    const text = await formatConversation(channelId, messages, settings.store.anonymize);
    await copyWithToast(text, `Copied ${messages.length} message${messages.length === 1 ? "" : "s"}`);
}

const messageContextMenuPatch: NavContextMenuPatchCallback = (children, { message }: { message?: Message; }) => {
    if (!message) return;

    // Read now, since clicking the menu item can clear the selection before the action runs.
    const selected = selectedMessages(message.channel_id);

    const item = (
        <Menu.MenuItem id="vc-copy-with-replies" label="Copy with Replies">
            <Menu.MenuItem
                id="vc-copy-with-replies-message"
                label="This Message"
                action={() => copyMessages(message.channel_id, [message])}
            />
            {selected.length > 0 && (
                <Menu.MenuItem
                    id="vc-copy-with-replies-selection"
                    label="Selected Messages"
                    action={() => copyMessages(message.channel_id, selected)}
                />
            )}
            <Menu.MenuItem
                id="vc-copy-with-replies-from-here"
                label="From Here Down"
                action={() => copyMessages(message.channel_id, messagesFrom(message))}
            />
            <Menu.MenuSeparator />
            {/* Patches cannot subscribe to settings, so close rather than leave a stale checkmark. */}
            <Menu.MenuCheckboxItem
                id="vc-copy-with-replies-anonymize"
                label="Random Names"
                checked={settings.store.anonymize}
                action={() => {
                    settings.store.anonymize = !settings.store.anonymize;
                    ContextMenuApi.closeContextMenu();
                }}
            />
        </Menu.MenuItem>
    );

    // Discord omits Copy Text on messages without text, such as attachment only ones.
    const group = findGroupChildrenByChildId("copy-text", children);
    if (group) group.splice(group.findIndex(c => c?.props?.id === "copy-text") + 1, 0, item);
    else children.push(item);
};

export default definePlugin({
    name: "CopyWithReplies",
    description: "Copies messages with their reply targets as plain text.",
    authors: [{ name: "dx", id: 0n }],
    tags: ["Chat", "Utility"],
    enabledByDefault: true,
    settings,

    contextMenus: {
        "message": messageContextMenuPatch
    },

    stop() {
        pseudonyms.clear();
    }
});
