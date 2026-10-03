- Replay file and memory sources now own their complete cursor, parser, pending
outcome and correspondence state. Refused memory replacements preserve the
active source; clearing memory resumes the suspended file without rewinding or
mixing queued values. Hosts explicitly advance concatenated tape sessions only
at quiescent boundaries with no unread current-session outcome. Continuing
attachments and children resolve the next namespace through lifetime metadata.
