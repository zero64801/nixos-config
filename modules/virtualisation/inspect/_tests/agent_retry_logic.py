"""The session helper's agent calls while a debugger halts the guest for moments, as guest-dbg's stops do: libvirt refuses
a command made during one, and by the time the guest's state is asked for, it runs again. The command has to be made
again until it goes through, while other refusals come back at once. libvirt is made up here.

usage: agent_retry_logic.py HELPER"""
import importlib.util
import sys
import types

libvirt = types.ModuleType("libvirt")
libvirt.VIR_DOMAIN_PAUSED, libvirt.VIR_DOMAIN_RUNNING, libvirt.VIR_ERR_OPERATION_INVALID, libvirt.VIR_ERR_AGENT_UNRESPONSIVE = 3, 1, 55, 86


class LibvirtError(Exception):
    def __init__(self, message, code):
        super().__init__(message)
        self.code = code

    def get_error_code(self):
        return self.code


libvirt.libvirtError = LibvirtError
answers = []


def command(guest, text, timeout, flags):
    reply = answers.pop(0)
    if isinstance(reply, Exception):
        raise reply
    return reply


libvirt_qemu = types.ModuleType("libvirt_qemu")
libvirt_qemu.qemuAgentCommand = command
sys.modules.update(libvirt=libvirt, libvirt_qemu=libvirt_qemu)
spec = importlib.util.spec_from_file_location("helper", sys.argv[1])
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class Guest:
    """A guest that runs again whenever its state is asked for."""

    def state(self):
        return libvirt.VIR_DOMAIN_RUNNING, 0


agent = object.__new__(helper.Agent)
agent.guest = Guest()
halted = LibvirtError("Requested operation is not valid: domain is not running", libvirt.VIR_ERR_OPERATION_INVALID)
answers[:] = [halted, halted, halted, '{"return": {}}']
assert agent.command('{"execute": "guest-ping"}') == ('{"return": {}}', None) and not answers, answers
print("ok: a command refused during a moment's halt goes through once the guest runs again")
answers[:] = [LibvirtError("Guest agent is not responding", libvirt.VIR_ERR_AGENT_UNRESPONSIVE), '{"return": {}}']
reply, why = agent.command('{"execute": "guest-ping"}')
assert reply is None and "not responding" in why and answers == ['{"return": {}}'], (reply, why)
print("ok: any other refusal comes back at once")
