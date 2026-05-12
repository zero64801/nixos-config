declare module "@utils/constants" {
  export type Dev = {
    name: string;
    id: string | bigint;
  };

  export const Devs: Record<string, Dev>;
}

declare module "@utils/types" {
  export type PluginAuthor = unknown;

  export type PluginDefinition = {
    name: string;
    description: string;
    authors: PluginAuthor[];
    start?: () => void;
    stop?: () => void;
    [key: string]: unknown;
  };

  export default function definePlugin<T extends PluginDefinition>(plugin: T): T;
}
