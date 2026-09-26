"""The piece of Claude Code and Codex the stubs need: start the Iris MCP server a session was given and call it."""
import json, subprocess


class MCP:
    def __init__(self, command, args):
        self.process = subprocess.Popen([command] + args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.next = 0
        self.request("initialize", {"protocolVersion": "2025-06-18", "clientInfo": {"name": "claude-code", "version": "stub"}})

    def request(self, method, params):
        self.next += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        return json.loads(self.process.stdout.readline())["result"]

    def call(self, name, arguments):
        """The tool's text and whether it failed."""
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        return result["content"][0]["text"], result.get("isError", False)

    def close(self):
        self.process.stdin.close()
        self.process.wait()
