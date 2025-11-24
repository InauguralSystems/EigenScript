# Date/Time Functions

Functions for working with dates, times, and timestamps in EigenScript.

---

## time_now

Get the current Unix timestamp.

**Syntax:**
```eigenscript
timestamp is time_now of 0
```

**Parameters:**
- Dummy parameter (use 0)

**Returns:** Current Unix timestamp (seconds since epoch)

**Example:**
```eigenscript
now is time_now of 0
print of now  # e.g., 1700000000.123
```

**Note:** Unix timestamps are in seconds since January 1, 1970 UTC.

---

## time_format

Format a timestamp as a string.

**Syntax:**
```eigenscript
formatted is time_format of [timestamp, format_string]
```

**Parameters:**
- `timestamp`: Unix timestamp (from `time_now`)
- `format_string`: Format specification (Python strftime format)

**Returns:** Formatted date/time string

**Example:**
```eigenscript
now is time_now of 0

# ISO 8601 format
iso is time_format of [now, "%Y-%m-%d %H:%M:%S"]
print of iso  # "2024-11-19 10:30:45"

# Human-readable
readable is time_format of [now, "%B %d, %Y at %I:%M %p"]
print of readable  # "November 19, 2024 at 10:30 AM"

# Date only
date is time_format of [now, "%Y-%m-%d"]
print of date  # "2024-11-19"

# Time only
time is time_format of [now, "%H:%M:%S"]
print of time  # "10:30:45"
```

**Format Codes:**
- `%Y` - Year (4 digits)
- `%m` - Month (01-12)
- `%d` - Day (01-31)
- `%H` - Hour (00-23)
- `%M` - Minute (00-59)
- `%S` - Second (00-59)
- `%I` - Hour (01-12)
- `%p` - AM/PM
- `%B` - Month name (full)
- `%b` - Month name (abbreviated)
- `%A` - Weekday name (full)
- `%a` - Weekday name (abbreviated)

---

## time_parse

Parse a time string into a Unix timestamp.

**Syntax:**
```eigenscript
timestamp is time_parse of [time_string, format_string]
```

**Parameters:**
- `time_string`: String to parse
- `format_string`: Format specification matching the input

**Returns:** Unix timestamp

**Example:**
```eigenscript
# Parse ISO format
time_str is "2024-11-19 10:30:45"
timestamp is time_parse of [time_str, "%Y-%m-%d %H:%M:%S"]
print of timestamp  # 1700393445.0

# Parse different format
date_str is "November 19, 2024"
ts is time_parse of [date_str, "%B %d, %Y"]
print of ts
```

**Note:** Uses same format codes as `time_format`.

**Error:** Raises error if string doesn't match format.

---

## Complete Examples

### Current Date and Time

```eigenscript
# Get and display current time
now is time_now of 0
formatted is time_format of [now, "%Y-%m-%d %H:%M:%S"]
print of "Current time: "
print of formatted
```

### Timestamping Events

```eigenscript
define log_event as:
    timestamp is time_now of 0
    formatted is time_format of [timestamp, "%Y-%m-%d %H:%M:%S"]
    
    print of formatted
    print of " - "
    print of message

log_event of "Application started"
log_event of "Processing data"
log_event of "Complete"
```

### Date Arithmetic

```eigenscript
# Get current time
now is time_now of 0

# Add one day (86400 seconds)
tomorrow is now + 86400
tomorrow_str is time_format of [tomorrow, "%Y-%m-%d"]
print of "Tomorrow: "
print of tomorrow_str

# Subtract one week (604800 seconds)
last_week is now - 604800
last_week_str is time_format of [last_week, "%Y-%m-%d"]
print of "Last week: "
print of last_week_str
```

### Time Difference

```eigenscript
# Calculate elapsed time
start is time_now of 0

# ... do some work ...

end is time_now of 0
elapsed is end - start

print of "Elapsed time: "
print of elapsed
print of " seconds"
```

### File Timestamp

```eigenscript
# Add timestamp to filename
now is time_now of 0
date_str is time_format of [now, "%Y%m%d_%H%M%S"]

filename is "backup_"
filename is filename + date_str
filename is filename + ".txt"

print of "Creating file: "
print of filename
# Output: "backup_20241119_103045.txt"
```

### Parse and Compare

```eigenscript
# Parse two dates and compare
date1_str is "2024-01-15"
date2_str is "2024-03-20"

ts1 is time_parse of [date1_str, "%Y-%m-%d"]
ts2 is time_parse of [date2_str, "%Y-%m-%d"]

if ts1 < ts2:
    print of "Date 1 is earlier"
else:
    print of "Date 2 is earlier"
```

### Format Date for Display

```eigenscript
# Show date in multiple formats
now is time_now of 0

iso is time_format of [now, "%Y-%m-%d"]
print of "ISO: "
print of iso

us is time_format of [now, "%m/%d/%Y"]
print of "US: "
print of us

eu is time_format of [now, "%d/%m/%Y"]
print of "EU: "
print of eu

full is time_format of [now, "%A, %B %d, %Y"]
print of "Full: "
print of full
```

---

## Time Constants

Useful constants for time calculations:

```eigenscript
# Seconds in common time periods
second is 1
minute is 60
hour is 3600
day is 86400
week is 604800
month_avg is 2592000    # 30 days
year is 31536000        # 365 days

# Example: Add 3 hours to current time
now is time_now of 0
later is now + (3 * hour)
formatted is time_format of [later, "%H:%M:%S"]
print of formatted
```

---

## Notes

### Timezone

All times are in UTC unless your system is configured otherwise. EigenScript uses the system's local timezone for formatting.

### Precision

Timestamps include fractional seconds (microseconds):

```eigenscript
now is time_now of 0
print of now  # e.g., 1700393445.123456
```

### Format String Reference

Common format patterns:

- **ISO 8601**: `"%Y-%m-%d %H:%M:%S"`
- **US Format**: `"%m/%d/%Y %I:%M %p"`
- **EU Format**: `"%d/%m/%Y %H:%M"`
- **Full Text**: `"%A, %B %d, %Y at %I:%M %p"`
- **Unix**: Use raw timestamp

---

## Summary

Date/Time functions provide:

- `time_now` - Get current timestamp
- `time_format` - Format timestamp as string
- `time_parse` - Parse string to timestamp

**Total: 3 functions**

These enable time-based operations, logging, and date calculations.

---

**Next:** [List Operations](lists.md) →
