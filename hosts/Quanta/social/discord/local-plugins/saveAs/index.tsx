import { findGroupChildrenByChildId, NavContextMenuPatchCallback } from "@api/ContextMenu";
import definePlugin, { PluginNative } from "@utils/types";
import { Message } from "@vencord/discord-types";
import { Menu, showToast } from "@webpack/common";

const Native = VencordNative.pluginHelpers.SaveAs as PluginNative<typeof import("./native")>;

type Attachment = { filename: string; url: string; };

async function saveAs({ filename, url }: Attachment) {
    try {
        // The CDN only sends CORS headers for images, so other files are fetched from the main process.
        const data = await Native.download(url);

        // The main process writes the file, so the renderer never needs access to the chosen folder.
        await DiscordNative.fileManager.saveWithDialog(data, filename);
    } catch (err) {
        showToast({ text: `Could not save ${filename}: ${err}`, variant: "critical" });
    }
}

const messageContextMenuPatch: NavContextMenuPatchCallback = (children, { message }: { message?: Message; }) => {
    if (!message) return;

    // A forward keeps its files on the snapshot, not on the message itself.
    const attachments = [...message.attachments, ...(message.messageSnapshots?.flatMap(s => s.message.attachments) ?? [])];
    if (!attachments.length) return;

    const item = attachments.length === 1
        ? <Menu.MenuItem id="vc-save-as" label="Save As..." action={() => saveAs(attachments[0])} />
        : (
            <Menu.MenuItem id="vc-save-as" label="Save As">
                {attachments.map((file: Attachment, i: number) => (
                    <Menu.MenuItem
                        key={i}
                        id={`vc-save-as-${i}`}
                        label={file.filename}
                        action={() => saveAs(file)}
                    />
                ))}
            </Menu.MenuItem>
        );

    const group = findGroupChildrenByChildId("copy-link", children);
    if (group) group.push(item);
    else children.push(item);
};

export default definePlugin({
    name: "SaveAs",
    description: "Saves message attachments through the native save dialog instead of the browser.",
    authors: [{ name: "dx", id: 0n }],
    tags: ["Utility"],
    enabledByDefault: true,

    contextMenus: {
        "message": messageContextMenuPatch
    }
});
