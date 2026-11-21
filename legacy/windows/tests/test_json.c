#include <assert.h>
#include <string.h>
#include "../json_buffer.h"

int main(void) {
    char bytes[128];
    JsonBuffer out = { bytes, 0, sizeof(bytes), 0 };
    const unsigned short title[] = { 'x', '"', '\\', '\n', 0, 0xc11c, 0xd83d, 0xde04, 0xdc00, 0xd800 };
    const char expected[] = "\"x\\\"\\\\\\u000a\\u0000\\uc11c\\ud83d\\ude04\\ufffd\\ufffd\"";
    append_title(&out, title, sizeof(title) / sizeof(title[0]));
    assert(!out.overflow && out.length == strlen(expected) && !memcmp(out.data, expected, out.length));

    out.length = 0;
    append_number(&out, 4294967295ul);
    append_byte(&out, ',');
    append_number(&out, 0);
    assert(out.length == 12 && !memcmp(out.data, "4294967295,0", 12));

    out.capacity = 2;
    out.length = 0;
    bytes[2] = '!';
    append_title(&out, title, 1);
    assert(out.overflow && out.length == 2 && bytes[2] == '!');
    return 0;
}
