import "./style.css";

import { ApplicationCommandInputType } from "@api/Commands";
import { getCurrentChannel } from "@utils/discord";
import { ModalCloseButton, ModalContent, ModalHeader, ModalProps, ModalRoot, ModalSize, openModal } from "@utils/modal";
import definePlugin from "@utils/types";
import { Guild, Role } from "@vencord/discord-types";
import { ChannelStore, ContextMenuApi, GuildMemberStore, GuildRoleStore, GuildStore, Menu, SelectedChannelStore, SelectedGuildStore, Text, UserProfileActions, UserStore } from "@webpack/common";

type RoleData = {
    guild: Guild;
    roles: Role[];
};

function getCurrentGuildId() {
    const currentChannel = getCurrentChannel();

    return currentChannel?.getGuildId?.()
        ?? SelectedGuildStore.getGuildId?.()
        ?? ChannelStore.getChannel(SelectedChannelStore.getChannelId())?.guild_id;
}

function getCurrentChannelId() {
    return getCurrentChannel()?.id ?? SelectedChannelStore.getChannelId();
}

function getMyRoleData(guildId = getCurrentGuildId()): RoleData | null {
    if (!guildId) return null;

    const guild = GuildStore.getGuild(guildId);
    const member = GuildMemberStore.getSelfMember(guildId);
    if (!guild || !member) return null;

    const roles = GuildRoleStore
        .getSortedRoles(guildId)
        .filter(role => role.id !== guildId && member.roles.includes(role.id));

    return { guild, roles };
}

function RolePill({ role }: { role: Role; }) {
    const color = role.colorString || "var(--text-muted)";

    return (
        <div className="vc-my-server-roles-role">
            <span className="vc-my-server-roles-dot" style={{ backgroundColor: color }} />
            <Text variant="text-md/medium" className="vc-my-server-roles-name">{role.name}</Text>
            {role.managed && (
                <Text variant="text-xs/medium" color="text-muted" className="vc-my-server-roles-managed">managed</Text>
            )}
        </div>
    );
}

function RolesModal({ data, ...props }: ModalProps & { data: RoleData | null; }) {
    const currentUser = UserStore.getCurrentUser();
    const title = data
        ? `${currentUser?.username ?? "My"} roles in ${data.guild.name}`
        : "My server roles";

    return (
        <ModalRoot {...props} size={ModalSize.SMALL}>
            <ModalHeader separator>
                <Text variant="heading-lg/semibold" className="vc-my-server-roles-title">{title}</Text>
                <ModalCloseButton onClick={props.onClose} />
            </ModalHeader>
            <ModalContent className="vc-my-server-roles-content">
                {!data ? (
                    <Text variant="text-md/normal" color="text-muted">
                        Open this from a server channel so I can read your server roles.
                    </Text>
                ) : data.roles.length === 0 ? (
                    <Text variant="text-md/normal" color="text-muted">
                        You do not have any assigned roles in this server.
                    </Text>
                ) : (
                    <>
                        <Text variant="text-sm/normal" color="text-muted" className="vc-my-server-roles-count">
                            {data.roles.length} assigned role{data.roles.length === 1 ? "" : "s"}
                        </Text>
                        <div className="vc-my-server-roles-list">
                            {data.roles.map(role => <RolePill key={role.id} role={role} />)}
                        </div>
                    </>
                )}
            </ModalContent>
        </ModalRoot>
    );
}

function openMyRolesModal(guildId?: string) {
    const data = getMyRoleData(guildId);

    openModal(props => <RolesModal {...props} data={data} />);
}

function openMyServerProfile(guildId = getCurrentGuildId()) {
    const currentUser = UserStore.getCurrentUser();

    if (!currentUser || !guildId) {
        openMyRolesModal(guildId);
        return;
    }

    try {
        UserProfileActions.openUserProfileModal({
            userId: currentUser.id,
            guildId,
            channelId: getCurrentChannelId(),
            analyticsLocation: {
                page: "Guild Channel",
                section: "Profile Popout"
            }
        });
    } catch {
        openMyRolesModal(guildId);
    }
}

function AccountPanelContextMenu() {
    const guildId = getCurrentGuildId();

    return (
        <Menu.Menu
            navId="vc-my-server-roles"
            onClose={ContextMenuApi.closeContextMenu}
        >
            <Menu.MenuItem
                id="vc-my-server-profile-open"
                label="View Server Profile"
                disabled={!guildId}
                action={() => openMyServerProfile(guildId)}
            />
            <Menu.MenuItem
                id="vc-my-server-roles-open"
                label="Show Role List"
                disabled={!guildId}
                action={() => openMyRolesModal(guildId)}
            />
        </Menu.Menu>
    );
}

export default definePlugin({
    name: "MyServerRoles",
    description: "Shows your roles in the current server without finding yourself in the member list.",
    authors: [{ name: "dx", id: 0n }],
    tags: ["Servers", "Utility"],
    enabledByDefault: true,

    patches: [
        {
            find: "handleOpenSettingsContextMenu=",
            replacement: {
                match: /ref:(\i),style:\i(?=.{0,250}#{intl::USER_PROFILE_ACCOUNT_POPOUT_BUTTON_A11Y_LABEL})/,
                replace: "$&,onContextMenu:$self.openAccountPanelContextMenu"
            }
        }
    ],

    commands: [
        {
            name: "myprofile",
            description: "Open your profile for the current server",
            inputType: ApplicationCommandInputType.BUILT_IN,
            execute: (_args, ctx) => openMyServerProfile(ctx.guild?.id)
        },
        {
            name: "myroles",
            description: "Show your roles in the current server",
            inputType: ApplicationCommandInputType.BUILT_IN,
            execute: (_args, ctx) => openMyRolesModal(ctx.guild?.id)
        }
    ],

    toolboxActions: {
        "Open My Server Profile": () => openMyServerProfile(),
        "Show My Server Roles": () => openMyRolesModal()
    },

    openAccountPanelContextMenu(event: React.UIEvent) {
        ContextMenuApi.openContextMenu(event, AccountPanelContextMenu);
    }
});
