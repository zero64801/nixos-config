import managedStyle from "./style.css?managed";

import { ChatBarButton, ChatBarButtonFactory } from "@api/ChatButtons";
import { findGroupChildrenByChildId, NavContextMenuPatchCallback } from "@api/ContextMenu";
import { DeleteIcon } from "@components/Icons";
import definePlugin from "@utils/types";
import { Channel, Message } from "@vencord/discord-types";
import { ContextMenuApi, Menu } from "@webpack/common";

import { openDeleteModal } from "./DeleteModal";
import { draggedJustNow, INTERACTIVE, startDragSelect, stopDragSelect } from "./drag";
import { settings } from "./settings";
import { canDelete, clearSelection, deselect, getRun, isRunning, isSelected, keepChannel, remaining, reset, rowClass, selectedCount, selectRange, toggle, useBulkDelete } from "./store";

const messageContextMenuPatch: NavContextMenuPatchCallback = (children, { message, channel }: { message?: Message; channel?: Channel; }) => {
    if (!message || !channel) return;

    const items: any[] = [];
    if (canDelete(message, channel)) {
        items.push(
            <Menu.MenuCheckboxItem
                key="vc-bulk-delete-select"
                id="vc-bulk-delete-select"
                label="Select for Deletion"
                checked={isSelected(message.id)}
                action={() => {
                    toggle(message);
                    // Patches cannot re-render, so close rather than leave a stale checkmark.
                    ContextMenuApi.closeContextMenu();
                }}
            />
        );
    }

    if (isRunning()) {
        items.push(
            <Menu.MenuItem key="vc-bulk-delete-open" id="vc-bulk-delete-open" label="Show Deletion Progress" action={openDeleteModal} />
        );
    } else if (selectedCount()) {
        items.push(
            <Menu.MenuItem
                key="vc-bulk-delete-open"
                id="vc-bulk-delete-open"
                label={`Delete ${selectedCount()} Selected...`}
                color="danger"
                action={openDeleteModal}
            />,
            <Menu.MenuItem key="vc-bulk-delete-clear" id="vc-bulk-delete-clear" label="Clear Selection" action={clearSelection} />
        );
    }
    if (!items.length) return;

    const group = findGroupChildrenByChildId("delete", children);
    if (group) group.splice(group.findIndex(child => child?.props?.id === "delete") + 1, 0, ...items);
    else children.push(<Menu.MenuGroup>{items}</Menu.MenuGroup>);
};

const SelectionButton: ChatBarButtonFactory = ({ isAnyChat }) => {
    useBulkDelete();

    const run = isRunning() ? getRun() : undefined;
    const count = run ? remaining(run) : selectedCount();
    if (!isAnyChat || (!run && !count)) return null;

    return (
        <ChatBarButton
            tooltip={run ? `Deleting, ${count} left` : `Delete ${count} selected (right click to clear)`}
            onClick={openDeleteModal}
            onContextMenu={() => {
                if (!run) clearSelection();
            }}
        >
            <span className={run ? "vc-bulk-delete-chat-icon vc-bulk-delete-running" : "vc-bulk-delete-chat-icon"}>
                <DeleteIcon width={20} height={20} />
                <span className="vc-bulk-delete-badge">{count}</span>
            </span>
        </ChatBarButton>
    );
};

export default definePlugin({
    name: "BulkDelete",
    description: "Select messages with right click, then click, drag or Shift+click more (Ctrl works without the menu), and delete them all at a human pace.",
    authors: [{ name: "dx", id: 0n }],
    tags: ["Chat", "Utility"],
    enabledByDefault: true,
    dependencies: ["MessageUpdaterAPI"],
    settings,
    managedStyle,

    patches: [
        {
            find: "Message must not be a thread starter message",
            replacement: {
                // Same anchor MessageLogger uses for its deleted class.
                match: /\)\("li",\{(.+?),className:/,
                replace: ")(\"li\",{$1,className:$self.rowClass(arguments[0].message.id)+"
            }
        }
    ],

    contextMenus: {
        "message": messageContextMenuPatch
    },

    chatBarButton: {
        icon: DeleteIcon,
        render: SelectionButton
    },

    flux: {
        CHANNEL_SELECT({ channelId }: { channelId: string | null; }) {
            if (!isRunning()) keepChannel(channelId);
        },
        MESSAGE_DELETE({ id }: { id: string; }) {
            deselect([id]);
        },
        MESSAGE_DELETE_BULK({ ids }: { ids: string[]; }) {
            deselect(ids);
        }
    },

    rowClass,

    onMessageClick(message: Message, channel: Channel, event: MouseEvent) {
        if (draggedJustNow() || event.defaultPrevented || (!selectedCount() && !event.ctrlKey)) return;
        if (!canDelete(message, channel) || (event.target as Element | null)?.closest(INTERACTIVE)) return;

        if (event.shiftKey) {
            selectRange(message, channel);
            // Shift+click also stretches the text selection, which is only noise here.
            document.getSelection()?.removeAllRanges();
        } else {
            // Selecting text with a drag also ends in a click.
            if (document.getSelection()?.isCollapsed === false) return;
            toggle(message);
        }
        event.preventDefault();
    },

    start() {
        startDragSelect();
    },

    stop() {
        stopDragSelect();
        reset();
    }
});
