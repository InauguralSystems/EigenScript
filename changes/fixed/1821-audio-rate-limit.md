- Refuse `audio_open` rates above 71,582,788 Hz, ensuring every accepted
  device rate can generate the full 30-second audio limit without overflowing
  the runtime's integer sample count.
