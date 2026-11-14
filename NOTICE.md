# Upstream attribution

This project is an independent derivative work based on the architecture and selected MIT-licensed transport concepts of Factorio LLM Use by Tsyklop.

- Upstream: https://github.com/Tsyklop/factorio-llm-use
- Inspected revision: 7a02d81af4fd354f4bf577f76703b4d3dbbecb0a (2026-11-04)
- Upstream license: MIT.

The original project supplies the baseline ideas for a persistent Factorio-side AI character, a loopback Source RCON bridge, and MCP tool exposure. The packet framing, serialized RCON transport and request-ID retry pattern in src/factorio_autonomous_engineer/bridge.py are adapted from its bridge.py. The Lua task, safety, strategic-profile, starting-site and lifecycle controllers are new implementations.

Any upstream source files copied into this project must retain their original copyright and license notices. New modules are separately authored. No affiliation with or endorsement by the upstream author is implied.
