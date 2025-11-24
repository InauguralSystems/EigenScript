# File I/O Functions

Functions for reading, writing, and managing files in EigenScript.

---

## File Operations

### file_open

Open a file for reading or writing.

**Syntax:**
```eigenscript
handle is file_open of [path, mode]
```

**Parameters:**
- `path`: String path to file
- `mode`: `"r"` (read), `"w"` (write), or `"a"` (append)

**Returns:** File handle object

**Example:**
```eigenscript
# Open for reading
handle is file_open of ["data.txt", "r"]

# Open for writing
handle is file_open of ["output.txt", "w"]

# Open for appending
handle is file_open of ["log.txt", "a"]
```

**Errors:**
- `FileNotFoundError` if file doesn't exist (read mode)
- `PermissionError` if no permission to access file

---

### file_read

Read contents from an open file.

**Syntax:**
```eigenscript
content is file_read of handle
```

**Parameters:**
- `handle`: File handle from `file_open`

**Returns:** String with file contents

**Example:**
```eigenscript
handle is file_open of ["data.txt", "r"]
content is file_read of handle
file_close of handle
print of content
```

---

### file_write

Write data to an open file.

**Syntax:**
```eigenscript
file_write of [handle, data]
```

**Parameters:**
- `handle`: File handle from `file_open`
- `data`: String to write

**Returns:** `null`

**Example:**
```eigenscript
handle is file_open of ["output.txt", "w"]
file_write of [handle, "Hello, file!"]
file_write of [handle, "\n"]
file_write of [handle, "Second line"]
file_close of handle
```

---

### file_close

Close an open file handle.

**Syntax:**
```eigenscript
file_close of handle
```

**Parameters:**
- `handle`: File handle to close

**Returns:** `null`

**Example:**
```eigenscript
handle is file_open of ["data.txt", "r"]
content is file_read of handle
file_close of handle
```

**Note:** Always close files when done to prevent resource leaks.

---

## File System Operations

### file_exists

Check if a file exists.

**Syntax:**
```eigenscript
exists is file_exists of path
```

**Parameters:**
- `path`: String path to check

**Returns:** `true` if exists, `false` otherwise

**Example:**
```eigenscript
exists is file_exists of "data.txt"
if exists:
    print of "File found!"
else:
    print of "File not found"
```

---

### file_size

Get the size of a file in bytes.

**Syntax:**
```eigenscript
size is file_size of path
```

**Parameters:**
- `path`: String path to file

**Returns:** Number of bytes

**Example:**
```eigenscript
size is file_size of "large_file.dat"
print of size  # e.g., 1048576 (1 MB)
```

**Error:** Raises error if file doesn't exist.

---

### list_dir

List contents of a directory.

**Syntax:**
```eigenscript
files is list_dir of path
```

**Parameters:**
- `path`: String path to directory

**Returns:** List of filenames

**Example:**
```eigenscript
files is list_dir of "."
print of files
# ["file1.txt", "file2.txt", "subdir"]
```

**Error:** Raises error if directory doesn't exist.

---

## Path Utilities

### dirname

Get the directory part of a path.

**Syntax:**
```eigenscript
dir is dirname of path
```

**Parameters:**
- `path`: String file path

**Returns:** Directory portion of path

**Example:**
```eigenscript
path is "/home/user/data.txt"
dir is dirname of path
print of dir  # "/home/user"
```

---

### basename

Get the filename part of a path.

**Syntax:**
```eigenscript
name is basename of path
```

**Parameters:**
- `path`: String file path

**Returns:** Filename portion of path

**Example:**
```eigenscript
path is "/home/user/data.txt"
name is basename of path
print of name  # "data.txt"
```

---

### absolute_path

Convert a relative path to an absolute path.

**Syntax:**
```eigenscript
abs_path is absolute_path of path
```

**Parameters:**
- `path`: String relative or absolute path

**Returns:** Absolute path string

**Example:**
```eigenscript
rel is "./data.txt"
abs is absolute_path of rel
print of abs  # "/home/user/project/data.txt"
```

---

## Complete Example

```eigenscript
# Read, process, and write a file
define process_file as:
    # Check if input exists
    exists is file_exists of "input.txt"
    if exists:
        # Read file
        handle is file_open of ["input.txt", "r"]
        content is file_read of handle
        file_close of handle
        
        # Process content
        upper_content is upper of content
        
        # Write result
        out_handle is file_open of ["output.txt", "w"]
        file_write of [out_handle, upper_content]
        file_close of out_handle
        
        print of "File processed successfully!"
    else:
        print of "Input file not found"

process_file of 0
```

## CSV Processing Example

```eigenscript
# Read and parse CSV file
handle is file_open of ["data.csv", "r"]
content is file_read of handle
file_close of handle

# Split into lines
lines is split of [content, "\n"]

# Process each line
define parse_csv_line as:
    fields is split of [line, ","]
    return fields

rows is map of [parse_csv_line, lines]
print of rows
```

## Log File Example

```eigenscript
# Append to log file
define log_message as:
    timestamp is time_now of 0
    formatted is time_format of [timestamp, "%Y-%m-%d %H:%M:%S"]
    
    handle is file_open of ["app.log", "a"]
    file_write of [handle, formatted]
    file_write of [handle, " - "]
    file_write of [handle, message]
    file_write of [handle, "\n"]
    file_close of handle

log_message of "Application started"
log_message of "Processing data..."
log_message of "Complete!"
```

## Summary

File I/O functions provide:

- **File Operations**: `file_open`, `file_read`, `file_write`, `file_close`
- **File System**: `file_exists`, `file_size`, `list_dir`
- **Path Utilities**: `dirname`, `basename`, `absolute_path`

**Total: 10 functions**

---

**Next:** [JSON Operations](json.md) →
