declare module "*.css";

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

declare module "@utils/types" {
  export const OptionType: {
    BOOLEAN: number;
    [key: string]: number;
  };

  export default function definePlugin<T extends Record<string, any>>(plugin: T): T;
}

declare module "@vencord/discord-types" {
  export interface Guild {
    id: string;
    name: string;
  }

  export interface Message {
    id: string;
    channel_id: string;
    type: number;
    content: string;
    timestamp: Date;
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
      };
    }[];
  }

  export interface Role {
    id: string;
    name: string;
    colorString?: string;
    managed?: boolean;
  }
}

declare module "@vencord/discord-types/enums" {
  export const enum MessageType {
    DEFAULT = 0,
    REPLY = 19,
    CHAT_INPUT_COMMAND = 20,
    CONTEXT_MENU_COMMAND = 23
  }
}

declare module "@webpack/common" {
  export const ChannelStore: any;
  export const ContextMenuApi: any;
  export const GuildMemberStore: any;
  export const GuildRoleStore: any;
  export const GuildStore: any;
  export const Menu: any;
  export const MessageStore: any;
  export const RestAPI: any;
  export const SelectedChannelStore: any;
  export const SelectedGuildStore: any;
  export const Text: any;
  export const UserProfileActions: any;
  export const UserStore: any;
}
