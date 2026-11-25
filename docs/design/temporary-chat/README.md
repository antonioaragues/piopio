# Temporary chats

`Options.html` (published as an artifact) holds two rounds, 2026-11-24:

1. Where a temporary chat shows and what you see when you come back to it: A (in Conversations, a strip on top),
   B (a Temporary folder, a card above the composer), C (the chat itself dashed). **The user chose A.**
2. How to turn one on: a corner button, a switch above the box, or the box's + menu. **The user first chose none of
   them and went back to round 1's chip in the box; on 2026-11-25 they switched to option 1, the corner button, as the
   pattern people know from other chat apps.**

As built: [spec 14 §8](../../spec/14-memory.md). Its mark is the mockup's dashed bubble: SF Symbols has none, so
the app masks gaps out of `bubble.left` itself (`TemporaryChatIcon` in Design.swift): the chat icon exactly, only
dashed. It's in the sidebar, the corner button, the New conversation page's mark, the strip and the menus. (From 2026-11-24 to 11-25 it was SF Symbols' `timer`.) New
Temporary Chat is ⌃⌘N (⇧⌘N is New Project), and the corner's tooltip says so.
