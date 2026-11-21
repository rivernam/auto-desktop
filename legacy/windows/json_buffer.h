#ifndef XP_JSON_BUFFER_H
#define XP_JSON_BUFFER_H

/* ASCII-only JSON is valid UTF-8 on every Windows code page. */
typedef struct {
    char *data;
    unsigned length;
    unsigned capacity;
    int overflow;
} JsonBuffer;

static void append_byte(JsonBuffer *out, char ch) {
    if (out->length < out->capacity) out->data[out->length++] = ch;
    else out->overflow = 1;
}

static void append_text(JsonBuffer *out, const char *s) {
    while (*s) append_byte(out, *s++);
}

static void append_number(JsonBuffer *out, unsigned long value) {
    char digits[3 * sizeof(value)];
    unsigned count = 0;
    do {
        digits[count++] = (char)('0' + value % 10);
        value /= 10;
    } while (value);
    while (count) append_byte(out, digits[--count]);
}

static void append_escape(JsonBuffer *out, unsigned unit) {
    static const char hex[] = "0123456789abcdef";
    int shift;
    append_text(out, "\\u");
    for (shift = 12; shift >= 0; shift -= 4) append_byte(out, hex[(unit >> shift) & 15]);
}

static void append_title(JsonBuffer *out, const unsigned short *s, unsigned length) {
    unsigned i;
    append_byte(out, '"');
    for (i = 0; i < length; i++) {
        unsigned unit = s[i];
        if (unit >= 0xd800 && unit <= 0xdbff && i + 1 < length &&
            s[i + 1] >= 0xdc00 && s[i + 1] <= 0xdfff) {
            append_escape(out, unit);
            append_escape(out, s[++i]);
        } else if (unit >= 0xd800 && unit <= 0xdfff) {
            append_escape(out, 0xfffd);
        } else if (unit < 0x20 || unit >= 0x7f) {
            append_escape(out, unit);
        } else {
            if (unit == '"' || unit == '\\') append_byte(out, '\\');
            append_byte(out, (char)unit);
        }
    }
    append_byte(out, '"');
}

#endif
