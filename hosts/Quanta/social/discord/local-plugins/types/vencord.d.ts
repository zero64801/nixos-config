declare module "*.css";

declare module "*.css?managed" {
  const name: string;
  export default name;
}

declare const DiscordNative: any;
declare const VencordNative: any;

declare module "electron" {
  export type IpcMainInvokeEvent = unknown;
  export const net: { fetch(url: string): Promise<Response>; };
}

declare namespace React {
  type ReactNode = unknown;

  interface UIEvent<T = Element> {
    currentTarget: T;
    preventDefault(): void;
    stopPropagation(): void;
  }
}

declare namespace JSX {
  interface IntrinsicAttributes {
    key?: any;
  }

  interface IntrinsicElements {
    [element: string]: any;
  }
}

declare module "@api/ChatButtons" {
  export type ChatBarButtonFactory = (props: {
    channel: any;
    isMainChat: boolean;
    isAnyChat: boolean;
  }) => any;

  export const ChatBarButton: any;
}

declare module "@api/MessageUpdater" {
  export function updateMessage(channelId: string, messageId: string, fields?: Record<string, any>): void;
}

declare module "@components/BaseText" {
  export const BaseText: any;
}

declare module "@components/Icons" {
  export const DeleteIcon: any;
}

declare module "@api/ContextMenu" {
  export type NavContextMenuPatchCallback = (children: any[], ...args: any[]) => void;

  export function findGroupChildrenByChildId(id: string | string[], children: any[], matchSubstring?: boolean): any[] | null;
}

declare module "@api/Settings" {
  export function definePluginSettings<T extends Record<string, any>>(def: T): {
    store: { [K in keyof T]: T[K] extends { default: infer D; } ? D : any; };
  };
}

declare module "@api/Commands" {
  export const ApplicationCommandInputType: {
    BUILT_IN: number;
  };
}

declare module "@utils/discord" {
  export function copyWithToast(text: string, toastMessage?: string): Promise<void>;
  export function getCurrentChannel(): any;
}

declare module "@utils/modal" {
  export interface ModalProps {
    onClose(): void;
    [key: string]: any;
  }

  export const ModalCloseButton: any;
  export const ModalContent: any;
  export const ModalHeader: any;
  export const ModalRoot: any;
  export const ModalSize: {
    SMALL: string;
    [key: string]: string;
  };

  export function openModal(render: (props: ModalProps) => any): void;
}

declare module "@utils/react" {
  export function useForceUpdater(): () => void;
  export function useTimer(opts: { interval?: number; deps?: unknown[]; }): number;
}

declare module "@utils/types" {
  export type PluginNative<T extends Record<string, (event: any, ...args: any[]) => any>> = {
    [K in keyof T]: T[K] extends (event: any, ...args: infer A) => infer R
      ? (...args: A) => R extends Promise<any> ? R : Promise<R>
      : never;
  };

  export const OptionType: {
    BOOLEAN: number;
    [key: string]: number;
  };

  export default function definePlugin<T extends Record<string, any>>(plugin: T): T;
}

declare module "@vencord/discord-types" {
  export interface Channel {
    id: string;
    guild_id: string | null;
    name: string;
    recipients: string[];
  }

  export interface Guild {
    id: string;
    name: string;
  }

  export interface Message {
    id: string;
    channel_id: string;
    type: number;
    state: "SENT" | "SENDING" | "SEND_FAILED";
    deleted?: boolean;
    content: string;
    timestamp: Date;
    embeds: unknown[];
    stickerItems?: unknown[];
    hasFlag(flag: number): boolean;
    author: {
      id: string;
      username: string;
      globalName?: string | null;
    };
    attachments: {
      filename: string;
      url: string;
    }[];
    messageReference?: {
      channel_id: string;
      message_id: string;
    };
    messageSnapshots?: {
      message: {
        content: string;
        attachments: {
          filename: string;
          url: string;
        }[];
      };
    }[];
  }

  export interface RenderModalProps {
    transitionState: number;
    onClose(): void;
  }

  export interface Role {
    id: string;
    name: string;
    colorString?: string;
    managed?: boolean;
  }
}

declare module "@vencord/discord-types/enums" {
  export const enum MessageFlags {
    EPHEMERAL = 64
  }

  export const enum MessageType {
    DEFAULT = 0,
    REPLY = 19,
    CHAT_INPUT_COMMAND = 20,
    CONTEXT_MENU_COMMAND = 23
  }
}

declare module "@webpack/common" {
  export const ChannelStore: any;
  export const Checkbox: any;
  export const Constants: any;
  export const ContextMenuApi: any;
  export const GuildMemberStore: any;
  export const GuildRoleStore: any;
  export const GuildStore: any;
  export const Menu: any;
  export const MessageStore: any;
  export const MessageTypeSets: Record<string, Set<number>>;
  export const Modal: any;
  export const PermissionsBits: Record<string, bigint>;
  export const PermissionStore: any;
  export const RestAPI: any;
  export const showToast: (message: string, type?: number) => void;
  export const SelectedChannelStore: any;
  export const SelectedGuildStore: any;
  export const Text: any;
  export const TextInput: any;
  export const Toasts: any;
  export const UserProfileActions: any;
  export const UserStore: any;

  export function openModal(render: (props: import("@vencord/discord-types").RenderModalProps) => any): string;
  export function useEffect(effect: () => void | (() => void), deps?: unknown[]): void;
  export function useState<T>(initial: T | (() => T)): [T, (value: T | ((previous: T) => T)) => void];
}
