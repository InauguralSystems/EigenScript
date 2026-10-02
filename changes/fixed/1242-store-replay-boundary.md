- Refuse every EigenStore operation during trace replay before accessing live
  storage, preventing changed or missing databases from silently corrupting a
  deterministic replay.
