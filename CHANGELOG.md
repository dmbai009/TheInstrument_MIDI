# Changelog

## Unreleased

- Extract the MIDI parser, validation, transfer accounting and timeline search into
  a dependency-free, tested core module.
- Validate streamed note data and cap decompression at 16 MB.
- Validate instrument ownership and parent amplifiers on the server.
- Add duplicate detection, byte accounting and pacing to band transfers.
- Replace linear seek and resync scans with binary search and bound playback work per
  frame for dense songs.
- Add LuaJIT regression tests and GitHub Actions CI.
- Add Workshop metadata, project artwork, documentation and an MIT license.
