#!/bin/sh
# CGI: GET /cgi-bin/files.sh?path=/some/dir
# Returns: {"files":[{"name":"...","type":"dir|file","path":"...","size":"..."}]}

echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

# Parse query string
path=$(echo "${QUERY_STRING}" | sed 's/.*path=\([^&]*\).*/\1/' | sed 's/%2F/\//g; s/%20/ /g; s/+/ /g')
[ -z "$path" ] && path="/"

# Security: prevent path traversal
path=$(echo "$path" | sed 's|//|/|g; s|\.\./||g')
[ -z "$path" ] && path="/"

# Check if directory exists
if [ ! -d "$path" ]; then
    echo "{\"error\":\"Directory not found: $path\"}"
    exit 0
fi

# List directory
OUTPUT="["
FIRST=1
for item in "$path"/* "$path"/.[!.]* 2>/dev/null; do
    [ -e "$item" ] || continue
    name=$(basename "$item")
    [ "$name" = "." ] || [ "$name" = ".." ] || continue 2>/dev/null

    if [ -d "$item" ]; then
        ftype="dir"
        fsize=""
    else
        ftype="file"
        fsize=$(ls -lh "$item" 2>/dev/null | awk '{print $5}')
    fi

    # Escape name for JSON
    jname=$(echo "$name" | sed 's/"/\\"/g')
    jpath=$(echo "$item" | sed 's/"/\\"/g')

    [ "$FIRST" = "1" ] && FIRST=0 || OUTPUT="$OUTPUT,"
    OUTPUT="${OUTPUT}{\"name\":\"${jname}\",\"type\":\"${ftype}\",\"path\":\"${jpath}\",\"size\":\"${fsize}\"}"
done

# Simpler approach: use ls
echo "{"
echo "\"path\": \"$(echo $path | sed 's/"/\\"/g')\","
echo "\"files\": ["

FIRST=1
ls -la "$path" 2>/dev/null | tail -n +4 | while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $NF}')
    [ "$name" = "." ] || [ "$name" = ".." ] || [ -z "$name" ] || continue 2>/dev/null

    perms=$(echo "$line" | awk '{print $1}')
    size=$(echo "$line" | awk '{print $5}')
    fpath="${path%/}/${name}"

    if echo "$perms" | grep -q '^d'; then
        ftype="dir"; fsize=""
    else
        ftype="file"
        # Human readable size
        if [ "$size" -gt 1048576 ] 2>/dev/null; then
            fsize="$(( size / 1048576 ))M"
        elif [ "$size" -gt 1024 ] 2>/dev/null; then
            fsize="$(( size / 1024 ))K"
        else
            fsize="${size}B"
        fi
    fi

    jname=$(echo "$name" | sed 's/"/\\"/g; s/\\/\\\\/g')
    jpath=$(echo "$fpath" | sed 's/"/\\"/g; s/\\/\\\\/g')

    if [ "$FIRST" = "1" ]; then FIRST=0; else echo ","; fi
    printf '{"name":"%s","type":"%s","path":"%s","size":"%s"}' "$jname" "$ftype" "$jpath" "$fsize"
done

echo ""
echo "]"
echo "}"
