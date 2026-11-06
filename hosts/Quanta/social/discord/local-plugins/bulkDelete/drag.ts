import { Message } from "@vencord/discord-types";
import { MessageStore } from "@webpack/common";

import { beginDrag, dragTo, endDrag, isRunning, isSelected, selectedCount } from "./store";

// Clicks on these keep doing their usual thing while selecting.
export const INTERACTIVE = "a, button, img, video, input, textarea, [role=button], [contenteditable=true]";

const ROW = 'li[id^="chat-messages-"]';
const EDGE = 48;
const SLOP = 6;

interface Drag {
    start: Message;
    erase: boolean;
    list: Element;
    startY: number;
    pointerY: number;
    over: string;
    active: boolean;
    frame: number;
}

let drag: Drag | undefined;
let justDragged = false;

export const draggedJustNow = () => justDragged;

function messageOf(row: Element | null | undefined): Message | undefined {
    const [, , channelId, messageId] = row?.id.split("-") ?? [];
    return messageId ? MessageStore.getMessage(channelId, messageId) : undefined;
}

function scrollerOf(row: Element) {
    for (let element = row.parentElement; element; element = element.parentElement) {
        const { overflowY } = getComputedStyle(element);
        if (overflowY === "auto" || overflowY === "scroll") return element;
    }
    return row.parentElement;
}

const speed = (distance: number) => Math.min(30, Math.ceil(distance / 3));

function onMouseDown(event: MouseEvent) {
    if (drag || event.button !== 0 || event.shiftKey || isRunning()) return;
    if (!selectedCount() && !event.ctrlKey) return;

    const target = event.target as Element;
    const row = target.closest?.(ROW);
    const start = messageOf(row);
    const list = row && scrollerOf(row);
    if (!start || !list || target.closest(INTERACTIVE)) return;

    // Otherwise the browser starts a text selection that fights the drag.
    event.preventDefault();
    document.getSelection()?.removeAllRanges();

    drag = {
        start,
        erase: isSelected(start.id),
        list,
        startY: event.clientY,
        pointerY: event.clientY,
        over: start.id,
        active: false,
        frame: requestAnimationFrame(follow)
    };
    window.addEventListener("mousemove", onMouseMove);
    window.addEventListener("mouseup", finish);
    window.addEventListener("blur", finish);
}

function onMouseMove(event: MouseEvent) {
    if (!drag) return;
    // The button was let go outside the window, where no mouseup arrives.
    if (!(event.buttons & 1)) return finish();
    drag.pointerY = event.clientY;
}

function follow() {
    if (!drag) return;

    const box = drag.list.getBoundingClientRect();
    const { pointerY, startY } = drag;
    if (pointerY < startY - SLOP && pointerY < box.top + EDGE) drag.list.scrollTop -= speed(box.top + EDGE - pointerY);
    else if (pointerY > startY + SLOP && pointerY > box.bottom - EDGE) drag.list.scrollTop += speed(pointerY - box.bottom + EDGE);

    // Only the height matters, and every element under the point is checked so floating bars cannot hide a row.
    const y = Math.min(Math.max(pointerY, box.top + 1), box.bottom - 1);
    const row = document.elementsFromPoint(box.left + box.width / 2, y).find(element => element.matches(ROW));
    const over = messageOf(row);
    if (over && over.channel_id === drag.start.channel_id && over.id !== drag.over) {
        if (!drag.active) beginDrag();
        drag.active = true;
        drag.over = over.id;
        dragTo(drag.start, over, drag.erase);
    }

    drag.frame = requestAnimationFrame(follow);
}

function finish() {
    if (!drag) return;

    cancelAnimationFrame(drag.frame);
    if (drag.active) {
        endDrag();
        // A drag that ends on a message also clicks it, and that click must not toggle it back.
        justDragged = true;
        setTimeout(() => justDragged = false);
    }
    drag = undefined;
    window.removeEventListener("mousemove", onMouseMove);
    window.removeEventListener("mouseup", finish);
    window.removeEventListener("blur", finish);
}

export function startDragSelect() {
    document.addEventListener("mousedown", onMouseDown, true);
}

export function stopDragSelect() {
    finish();
    document.removeEventListener("mousedown", onMouseDown, true);
}
