package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;

/** Coordinate arithmetic for physical input. Every value is in physical pixels unless noted. */
final class InputGeometry {
    /** A rectangle with exclusive right and bottom edges, as GetWindowRect returns it. */
    static final class Rect {
        final int left;
        final int top;
        final int right;
        final int bottom;

        Rect(int left, int top, int right, int bottom) {
            this.left = left;
            this.top = top;
            this.right = right;
            this.bottom = bottom;
        }

        int width() { return right - left; }

        int height() { return bottom - top; }

        boolean contains(int x, int y) { return x >= left && x < right && y >= top && y < bottom; }

        @Override public String toString() { return "[" + left + "," + top + "," + right + "," + bottom + "]"; }
    }

    /** Element bounds as a backend reported them: origin and size, possibly in another coordinate space. */
    static final class Bounds {
        final double x;
        final double y;
        final double width;
        final double height;

        Bounds(double x, double y, double width, double height) {
            this.x = x;
            this.y = y;
            this.width = width;
            this.height = height;
        }

        static Bounds read(JsonNode node) {
            if (node == null || !node.isObject()) return null;
            for (String axis : new String[] {"x", "y", "width", "height"})
                if (!node.path(axis).isNumber() || !Double.isFinite(node.get(axis).doubleValue())) return null;
            return new Bounds(node.get("x").doubleValue(), node.get("y").doubleValue(),
                    node.get("width").doubleValue(), node.get("height").doubleValue());
        }

        boolean sameAs(Bounds other) {
            return other != null && x == other.x && y == other.y && width == other.width && height == other.height;
        }
    }

    /** How a backend's bounds relate to physical screen pixels. */
    static final class Mapping {
        final String kind;
        private final double scaleX;
        private final double scaleY;
        private final double fromX;
        private final double fromY;
        private final double toX;
        private final double toY;

        private Mapping(String kind, double scaleX, double scaleY, double fromX, double fromY, double toX, double toY) {
            this.kind = kind;
            this.scaleX = scaleX;
            this.scaleY = scaleY;
            this.fromX = fromX;
            this.fromY = fromY;
            this.toX = toX;
            this.toY = toY;
        }

        static Mapping identity(String kind) { return new Mapping(kind, 1, 1, 0, 0, 0, 0); }

        Bounds apply(Bounds b) {
            return new Bounds(toX + (b.x - fromX) * scaleX, toY + (b.y - fromY) * scaleY, b.width * scaleX, b.height * scaleY);
        }
    }

    /**
     * Compares the live window rectangle with the backend's live bounds of the same window. A
     * backend whose numbers differ by a uniform scale, such as Java Access Bridge in a HiDPI JVM,
     * is mapped through the window origin. Anything else is refused.
     */
    static Mapping mapping(Rect window, Bounds root) {
        if (root == null || root.width <= 0 || root.height <= 0 || window.width() <= 0 || window.height() <= 0)
            throw unverified();
        double sx = window.width() / root.width;
        double sy = window.height() / root.height;
        if (physicalMatch(window, root))
            return Mapping.identity("physical");
        if (sx >= 0.5 && sx <= 4 && sy >= 0.5 && sy <= 4 && Math.abs(sx / sy - 1) <= 0.02)
            return new Mapping("scaled", sx, sy, root.x, root.y, window.left, window.top);
        throw unverified();
    }

    static boolean physicalMatch(Rect rect, Bounds root) {
        return rect != null && root != null && root.width > 0 && root.height > 0
                && Math.abs(rect.width() / root.width - 1) <= 0.01
                && Math.abs(rect.height() / root.height - 1) <= 0.01
                && Math.abs(root.x - rect.left) <= 2 && Math.abs(root.y - rect.top) <= 2;
    }

    /** The pixel at the given fractions of the bounds. A fraction of 1 is the last pixel inside. */
    static int[] point(Bounds bounds, double fx, double fy) {
        long left = round(bounds.x);
        long top = round(bounds.y);
        long width = round(bounds.width);
        long height = round(bounds.height);
        if (width < 1 || height < 1)
            throw new AgentException("PRECONDITION_FAILED", "The element has no clickable area.");
        long x = left + round(fx * (width - 1));
        long y = top + round(fy * (height - 1));
        if (x < Integer.MIN_VALUE || x > Integer.MAX_VALUE || y < Integer.MIN_VALUE || y > Integer.MAX_VALUE)
            throw unverified();
        return new int[] {(int) x, (int) y};
    }

    /** Half rounds up on both signs, the same in the Java and C++ agents. */
    static long round(double value) {
        return (long) Math.floor(value + 0.5);
    }

    /**
     * Normalized absolute coordinate on the virtual desktop for MOUSEEVENTF_VIRTUALDESK. Windows
     * maps n back to origin + floor(n * size / 65536), so the ceiling lands on the requested pixel.
     */
    static int normalize(int pixel, int origin, int size) {
        if (size <= 0 || size >= 65536 || pixel < origin || pixel - (long) origin >= size)
            throw new AgentException("PRECONDITION_FAILED", "The point is outside the virtual screen.");
        long offset = pixel - (long) origin;
        return (int) ((offset * 65536 + size - 1) / size);
    }

    /** The pixel that Windows derives from a normalized coordinate. Used by tests to check normalize. */
    static int denormalize(int normalized, int origin, int size) {
        return origin + (int) (((long) normalized * size) >> 16);
    }

    static AgentException unverified() {
        return new AgentException("BOUNDS_UNVERIFIED", "The element bounds could not be related to screen pixels.");
    }

    private InputGeometry() {}
}
