// coastline_app._kernels: the app's hot loops in C++ (pybind11).
//
// DexelGrid is a port of DexelSim.swift (CoastlineCore/Sim): Z-dexels over the work XY, per column
// the Z spans (sorted, merged) a tool swept. Float spans and double geometry, as in Swift, so the
// results match the Swift app's.

#include <pybind11/numpy.h>
#include <pybind11/pybind11.h>
#include <pybind11/stl.h>

#include <algorithm>
#include <functional>
#include <cmath>
#include <utility>
#include <vector>

namespace py = pybind11;

struct Span {
    float lo, hi;
};

enum class ToolKind { flat = 0, ball = 1, drill = 2, disc = 3 };

struct ToolShape {
    ToolKind kind;
    double radius, length, discThickness, shankRadius;

    // The Z ranges above the tip the tool fills at distance r from its axis.
    inline void ranges(double r, double& lo, double& hi) const {
        lo = 1.0;
        hi = 0.0;
        if (r > radius) return;
        switch (kind) {
            case ToolKind::flat: lo = 0; hi = length; return;
            case ToolKind::ball: lo = radius - std::sqrt(radius * radius - r * r); hi = length; return;
            case ToolKind::drill: lo = r / std::tan(59 * M_PI / 180); hi = length; return;
            case ToolKind::disc:
                if (r <= shankRadius) { lo = 0; hi = length; return; }
                lo = 0; hi = discThickness; return;
        }
    }
};

class DexelGrid {
public:
    double originX, originY, cell;
    int cols, rows;
    std::vector<std::vector<Span>> spans;

    DexelGrid(double minX, double minY, double maxX, double maxY, double cell_) : cell(cell_) {
        cols = std::max((int)std::ceil((maxX - minX) / cell), 1);
        rows = std::max((int)std::ceil((maxY - minY) / cell), 1);
        originX = minX + cell / 2;
        originY = minY + cell / 2;
        spans.assign((size_t)cols * rows, {});
    }

    std::pair<double, double> centre(int c, int r) const { return {originX + c * cell, originY + r * cell}; }

    void add(size_t index, float lo, float hi) {
        if (!(hi > lo)) return;
        auto& list = spans[index];
        float a = lo, b = hi;
        std::vector<Span> out;
        out.reserve(list.size() + 1);
        bool placed = false;
        for (const auto& s : list) {
            if (s.hi < a) { out.push_back(s); continue; }
            if (s.lo > b) {
                if (!placed) { out.push_back({a, b}); placed = true; }
                out.push_back(s);
                continue;
            }
            a = std::min(a, s.lo);
            b = std::max(b, s.hi);
        }
        if (!placed) out.push_back({a, b});
        list.swap(out);
    }

    void sweep(double ax, double ay, double az, double bx, double by, double bz, const ToolShape& tool) {
        int pieces = std::max(1, (int)std::ceil(std::abs(bz - az) / cell));
        for (int k = 0; k < pieces; ++k) {
            double t0 = (double)k / pieces, t1 = (double)(k + 1) / pieces;
            sweepPiece(ax + (bx - ax) * t0, ay + (by - ay) * t0, az + (bz - az) * t0,
                       ax + (bx - ax) * t1, ay + (by - ay) * t1, az + (bz - az) * t1, tool);
        }
    }

    void sweepPiece(double px, double py, double pz, double qx, double qy, double qz, const ToolShape& tool) {
        double r = tool.radius;
        double dx = qx - px, dy = qy - py;
        double len2 = dx * dx + dy * dy;
        double zlo = std::min(pz, qz), zhi = std::max(pz, qz);
        int c0 = std::max(0, (int)std::floor((std::min(px, qx) - r - originX) / cell));
        int c1 = std::min(cols - 1, (int)std::ceil((std::max(px, qx) + r - originX) / cell));
        int r0 = std::max(0, (int)std::floor((std::min(py, qy) - r - originY) / cell));
        int r1 = std::min(rows - 1, (int)std::ceil((std::max(py, qy) + r - originY) / cell));
        if (c0 > c1 || r0 > r1) return;
        for (int row = r0; row <= r1; ++row) {
            for (int col = c0; col <= c1; ++col) {
                double cx = originX + col * cell, cy = originY + row * cell;
                double t = len2 > 0 ? std::min(std::max(((cx - px) * dx + (cy - py) * dy) / len2, 0.0), 1.0) : 0.0;
                double ex = cx - (px + dx * t), ey = cy - (py + dy * t);
                double dist = std::sqrt(ex * ex + ey * ey);
                if (!(dist <= r)) continue;
                double lo, hi;
                tool.ranges(dist, lo, hi);
                add((size_t)row * cols + col, (float)(zlo + lo), (float)(zhi + hi));
            }
        }
    }

    // Sweeps along consecutive points (N×3): a polyline the tool follows.
    void sweepPath(py::array_t<double, py::array::c_style | py::array::forcecast> points, const ToolShape& tool) {
        auto p = points.unchecked<2>();
        for (py::ssize_t i = 1; i < p.shape(0); ++i)
            sweep(p(i - 1, 0), p(i - 1, 1), p(i - 1, 2), p(i, 0), p(i, 1), p(i, 2), tool);
    }

    void fill(py::array_t<float, py::array::c_style | py::array::forcecast> vertices,
              py::array_t<uint32_t, py::array::c_style | py::array::forcecast> indices) {
        auto v = vertices.unchecked<1>();
        auto ix = indices.unchecked<1>();
        std::vector<std::vector<float>> hits((size_t)cols * rows);
        double jx = cell * 0.000137, jy = cell * 0.000291;
        auto get = [&](uint32_t i, double& x, double& y, double& z) {
            size_t k = (size_t)i * 3;
            x = v(k); y = v(k + 1); z = v(k + 2);
        };
        py::ssize_t n = ix.shape(0);
        for (py::ssize_t t = 0; t + 2 < n; t += 3) {
            double ax, ay, az, bx, by, bz, cx, cy, cz;
            get(ix(t), ax, ay, az);
            get(ix(t + 1), bx, by, bz);
            get(ix(t + 2), cx, cy, cz);
            double det = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay);
            if (!(std::abs(det) > 1e-12)) continue;
            int c0 = std::max(0, (int)std::floor((std::min({ax, bx, cx}) - originX) / cell));
            int c1 = std::min(cols - 1, (int)std::ceil((std::max({ax, bx, cx}) - originX) / cell));
            int r0 = std::max(0, (int)std::floor((std::min({ay, by, cy}) - originY) / cell));
            int r1 = std::min(rows - 1, (int)std::ceil((std::max({ay, by, cy}) - originY) / cell));
            if (c0 > c1 || r0 > r1) continue;
            for (int row = r0; row <= r1; ++row) {
                for (int col = c0; col <= c1; ++col) {
                    double qx = originX + col * cell + jx, qy = originY + row * cell + jy;
                    double w1 = ((qx - ax) * (cy - ay) - (cx - ax) * (qy - ay)) / det;
                    double w2 = ((bx - ax) * (qy - ay) - (qx - ax) * (by - ay)) / det;
                    if (!(w1 >= 0 && w2 >= 0 && w1 + w2 <= 1)) continue;
                    hits[(size_t)row * cols + col].push_back((float)(az + (bz - az) * w1 + (cz - az) * w2));
                }
            }
        }
        for (size_t i = 0; i < hits.size(); ++i) {
            auto& z = hits[i];
            if (z.size() < 2) continue;
            std::sort(z.begin(), z.end());
            for (size_t k = 0; k + 1 < z.size(); k += 2) add(i, z[k], z[k + 1]);
        }
    }

    DexelGrid intersection(const DexelGrid& o, float minimum) const {
        DexelGrid out = *this;
        for (size_t i = 0; i < spans.size(); ++i) {
            std::vector<Span> both;
            for (const auto& s : spans[i])
                for (const auto& q : o.spans[i]) {
                    float lo = std::max(s.lo, q.lo), hi = std::min(s.hi, q.hi);
                    if (hi - lo > minimum) both.push_back({lo, hi});
                }
            out.spans[i] = std::move(both);
        }
        return out;
    }

    DexelGrid clipped(double lx, double ly, double lz, double hx, double hy, double hz) const {
        DexelGrid out = *this;
        for (int row = 0; row < rows; ++row)
            for (int col = 0; col < cols; ++col) {
                double cx = originX + col * cell, cy = originY + row * cell;
                size_t i = (size_t)row * cols + col;
                if (!(cx >= lx && cx <= hx && cy >= ly && cy <= hy)) { out.spans[i].clear(); continue; }
                std::vector<Span> kept;
                for (const auto& s : spans[i]) {
                    float a = std::max(s.lo, (float)lz), b = std::min(s.hi, (float)hz);
                    if (b > a) kept.push_back({a, b});
                }
                out.spans[i] = std::move(kept);
            }
        return out;
    }

    DexelGrid subtracting(const DexelGrid& o, float minimum) const {
        DexelGrid out = *this;
        for (size_t i = 0; i < spans.size(); ++i) {
            std::vector<Span> rest;
            for (const auto& s : spans[i]) {
                float a = s.lo;
                for (const auto& q : o.spans[i]) {
                    if (!(q.hi > a && q.lo < s.hi)) continue;
                    if (q.lo - a > minimum) rest.push_back({a, q.lo});
                    a = std::max(a, q.hi);
                }
                if (s.hi - a > minimum) rest.push_back({a, s.hi});
            }
            out.spans[i] = std::move(rest);
        }
        return out;
    }

    double volume() const {
        double total = 0;
        for (const auto& list : spans) {
            double column = 0;
            for (const auto& s : list) column += (double)(s.hi - s.lo);
            total += column;
        }
        return total * cell * cell;
    }

    bool empty() const {
        for (const auto& list : spans)
            if (!list.empty()) return false;
        return true;
    }

    py::tuple mesh() const {
        std::vector<float> pos, nrm;
        std::vector<uint32_t> idx;
        auto quad = [&](float a0, float a1, float a2, float b0, float b1, float b2, float c0, float c1, float c2,
                        float d0, float d1, float d2, float n0, float n1, float n2) {
            uint32_t base = (uint32_t)(pos.size() / 3);
            float pts[12] = {a0, a1, a2, b0, b1, b2, c0, c1, c2, d0, d1, d2};
            for (int k = 0; k < 4; ++k) {
                pos.insert(pos.end(), {pts[3 * k], pts[3 * k + 1], pts[3 * k + 2]});
                nrm.insert(nrm.end(), {n0, n1, n2});
            }
            idx.insert(idx.end(), {base, base + 1, base + 2, base, base + 2, base + 3});
        };
        auto uncovered = [](float lo, float hi, const std::vector<Span>& cover) {
            std::vector<Span> out;
            float a = lo;
            for (const auto& s : cover) {
                if (!(s.hi > a && s.lo < hi)) continue;
                if (s.lo > a) out.push_back({a, s.lo});
                a = std::max(a, s.hi);
                if (a >= hi) break;
            }
            if (a < hi) out.push_back({a, hi});
            return out;
        };
        float h = (float)(cell / 2);
        static const std::vector<Span> none;
        const int dcs[4] = {1, -1, 0, 0}, drs[4] = {0, 0, 1, -1};
        for (int row = 0; row < rows; ++row)
            for (int col = 0; col < cols; ++col) {
                const auto& list = spans[(size_t)row * cols + col];
                if (list.empty()) continue;
                double cx = originX + col * cell, cy = originY + row * cell;
                float x0 = (float)cx - h, x1 = (float)cx + h, y0 = (float)cy - h, y1 = (float)cy + h;
                for (const auto& s : list) {
                    quad(x0, y0, s.hi, x1, y0, s.hi, x1, y1, s.hi, x0, y1, s.hi, 0, 0, 1);
                    quad(x0, y0, s.lo, x0, y1, s.lo, x1, y1, s.lo, x1, y0, s.lo, 0, 0, -1);
                    for (int k = 0; k < 4; ++k) {
                        int nc = col + dcs[k], nr = row + drs[k];
                        bool inside = nc >= 0 && nc < cols && nr >= 0 && nr < rows;
                        const auto& cover = inside ? spans[(size_t)nr * cols + nc] : none;
                        for (const auto& w : uncovered(s.lo, s.hi, cover)) {
                            if (k == 0) quad(x1, y0, w.lo, x1, y1, w.lo, x1, y1, w.hi, x1, y0, w.hi, 1, 0, 0);
                            else if (k == 1) quad(x0, y1, w.lo, x0, y0, w.lo, x0, y0, w.hi, x0, y1, w.hi, -1, 0, 0);
                            else if (k == 2) quad(x1, y1, w.lo, x0, y1, w.lo, x0, y1, w.hi, x1, y1, w.hi, 0, 1, 0);
                            else quad(x0, y0, w.lo, x1, y0, w.lo, x1, y0, w.hi, x0, y0, w.hi, 0, -1, 0);
                        }
                    }
                }
            }
        py::array_t<float> p({(py::ssize_t)(pos.size() / 3), (py::ssize_t)3});
        py::array_t<float> n({(py::ssize_t)(nrm.size() / 3), (py::ssize_t)3});
        py::array_t<uint32_t> i((py::ssize_t)idx.size());
        std::copy(pos.begin(), pos.end(), p.mutable_data());
        std::copy(nrm.begin(), nrm.end(), n.mutable_data());
        std::copy(idx.begin(), idx.end(), i.mutable_data());
        return py::make_tuple(p, n, i);
    }

    py::list getSpans(size_t index) const {
        py::list out;
        for (const auto& s : spans.at(index)) out.append(py::make_tuple(s.lo, s.hi));
        return out;
    }

    void setSpans(size_t index, const std::vector<std::pair<float, float>>& list) {
        auto& dst = spans.at(index);
        dst.clear();
        for (const auto& s : list) dst.push_back({s.first, s.second});
    }

    // Whether column (c, r) holds a span reaching into [lo - tol, hi + tol]; for quick probes.
    bool anyIn(size_t index, float lo, float hi) const {
        for (const auto& s : spans.at(index))
            if (s.lo <= hi && lo <= s.hi) return true;
        return false;
    }

    // Adds every span of `other` (same grid layout) to this grid: the union of two solids.
    void merge(const DexelGrid& other) {
        size_t n = std::min(spans.size(), other.spans.size());
        for (size_t i = 0; i < n; i++)
            for (const auto& s : other.spans[i]) add(i, s.lo, s.hi);
    }

    // All spans as flat arrays: rows offsets[k] … offsets[k + 1] of `spans` are cell k's (lo, hi).
    py::tuple flat() const {
        size_t n = spans.size(), m = 0;
        for (const auto& l : spans) m += l.size();
        py::array_t<int64_t> offsets((py::ssize_t)(n + 1));
        py::array_t<float> rows({(py::ssize_t)m, (py::ssize_t)2});
        auto o = offsets.mutable_unchecked<1>();
        auto r = rows.mutable_unchecked<2>();
        size_t k = 0;
        for (size_t i = 0; i < n; i++) {
            o((py::ssize_t)i) = (int64_t)k;
            for (const auto& s : spans[i]) { r((py::ssize_t)k, 0) = s.lo; r((py::ssize_t)k, 1) = s.hi; k++; }
        }
        o((py::ssize_t)n) = (int64_t)k;
        return py::make_tuple(offsets, rows);
    }

    // Per query: whether [lo, hi] in cell `cells[q]` is covered by its spans (gaps under 1e-5
    // bridged), walking them in order as LibraryWorkholdingPlanner's fitsRemainingStock does.
    py::array_t<bool> covered(py::array_t<int64_t, py::array::c_style | py::array::forcecast> cells,
                              py::array_t<double, py::array::c_style | py::array::forcecast> lo,
                              py::array_t<double, py::array::c_style | py::array::forcecast> hi) const {
        auto c = cells.unchecked<1>(); auto a = lo.unchecked<1>(); auto b = hi.unchecked<1>();
        py::ssize_t n = c.shape(0);
        py::array_t<bool> out(n);
        auto o = out.mutable_unchecked<1>();
        for (py::ssize_t q = 0; q < n; q++) {
            double cov = a(q), top = b(q);
            for (const auto& s : spans.at((size_t)c(q))) {
                if ((double)s.hi < cov) continue;
                if ((double)s.lo > cov + 1e-5) break;
                cov = std::max(cov, (double)s.hi);
                if (cov >= top) break;
            }
            o(q) = cov >= top;
        }
        return out;
    }

    // Per query point (column, row, w): a span within `tol` of w in the 3×3 cells around it
    // (StockRemoval.removed). Columns/rows outside −1 … cols/rows don't count.
    py::array_t<bool> near(py::array_t<int64_t, py::array::c_style | py::array::forcecast> colsIn,
                           py::array_t<int64_t, py::array::c_style | py::array::forcecast> rowsIn,
                           py::array_t<double, py::array::c_style | py::array::forcecast> wIn, double tol) const {
        auto cc = colsIn.unchecked<1>(); auto rr = rowsIn.unchecked<1>(); auto ww = wIn.unchecked<1>();
        py::ssize_t n = cc.shape(0);
        py::array_t<bool> out(n);
        auto o = out.mutable_unchecked<1>();
        for (py::ssize_t q = 0; q < n; q++) {
            int64_t col = cc(q), row = rr(q);
            double w = ww(q);
            bool hit = false;
            if (col >= -1 && row >= -1 && col <= cols && row <= rows) {
                for (int64_t r = std::max<int64_t>(row - 1, 0); r <= std::min<int64_t>(row + 1, rows - 1) && !hit; r++)
                    for (int64_t c = std::max<int64_t>(col - 1, 0); c <= std::min<int64_t>(col + 1, cols - 1) && !hit; c++)
                        for (const auto& s : spans[(size_t)(r * cols + c)])
                            if ((double)s.lo - tol <= w && w <= (double)s.hi + tol) { hit = true; break; }
            }
            o(q) = hit;
        }
        return out;
    }
};


// ---------------------------------------------------------------- stock model (StockModel.swift)

struct Cutter {
    int tip;  // 0 flat, 1 ball, 2 corner, 3 cone
    double radius, start, length, crossLength, corner, halfAngle;

    inline bool offset(double d, double& out) const {
        if (!(d <= radius)) return false;
        switch (tip) {
            case 0: out = 0; return true;
            case 1: out = radius - std::sqrt(radius * radius - d * d); return true;
            case 2: {
                double flat = radius - corner;
                if (!(d > flat)) { out = 0; return true; }
                double e = d - flat;
                out = corner - std::sqrt(std::max(corner * corner - e * e, 0.0));
                return true;
            }
            default: out = d / std::tan(halfAngle); return true;
        }
    }
};

static inline void plane(int k, int& a, int& b) {
    if (k == 0) { a = 1; b = 2; } else if (k == 1) { a = 0; b = 2; } else { a = 0; b = 1; }
}

// A removed span into a column, nothing done when one already covers it.
static inline void addUncovered(DexelGrid& g, size_t i, float lo, float hi) {
    if (!(hi > lo)) return;
    for (const auto& s : g.spans[i])
        if (s.lo <= lo && s.hi >= hi) return;
    g.add(i, lo, hi);
}

static bool capsule(double p0x, double p0y, double p1x, double p1y, double r, double c, double& lo, double& hi) {
    lo = INFINITY; hi = -INFINITY;
    double P[2][2] = {{p0x, p0y}, {p1x, p1y}};
    for (int k = 0; k < 2; ++k) {
        double dy = c - P[k][1];
        if (std::abs(dy) <= r) {
            double w = std::sqrt(r * r - dy * dy);
            lo = std::min(lo, P[k][0] - w);
            hi = std::max(hi, P[k][0] + w);
        }
    }
    double dx = p1x - p0x, dy = p1y - p0y, len = std::sqrt(dx * dx + dy * dy);
    if (len > 1e-9) {
        double ux = dx / len, uy = dy / len, nx = -uy, ny = ux;
        double a = -INFINITY, b = INFINITY;
        auto within = [&](double slope, double offset, double low, double high) {
            if (std::abs(slope) < 1e-12) return offset >= low && offset <= high;
            double x0 = (low - offset) / slope, x1 = (high - offset) / slope;
            if (x0 > x1) std::swap(x0, x1);
            a = std::max(a, x0);
            b = std::min(b, x1);
            return true;
        };
        bool ok = within(nx, (c - p0y) * ny - p0x * nx, -r, r);
        ok = ok && within(ux, (c - p0y) * uy - p0x * ux, 0, len);
        if (ok && a <= b) { lo = std::min(lo, a); hi = std::max(hi, b); }
    }
    return lo <= hi;
}

static void sweepAlong(DexelGrid& g, const double* p, const double* q, int j, double sign, const Cutter& c) {
    int a, b;
    plane(j, a, b);
    double cell = g.cell, r = c.radius;
    double p2x = p[a], p2y = p[b], q2x = q[a], q2y = q[b], dx = q2x - p2x, dy = q2y - p2y;
    double len2 = dx * dx + dy * dy;
    double wlo = std::min(p[j], q[j]), whi = std::max(p[j], q[j]);
    int c0 = std::max(0, (int)std::floor((std::min(p2x, q2x) - r - g.originX) / cell));
    int c1 = std::min(g.cols - 1, (int)std::ceil((std::max(p2x, q2x) + r - g.originX) / cell));
    int r0 = std::max(0, (int)std::floor((std::min(p2y, q2y) - r - g.originY) / cell));
    int r1 = std::min(g.rows - 1, (int)std::ceil((std::max(p2y, q2y) + r - g.originY) / cell));
    if (c0 > c1 || r0 > r1) return;
    for (int row = r0; row <= r1; ++row)
        for (int col = c0; col <= c1; ++col) {
            double x = g.originX + col * cell, y = g.originY + row * cell;
            double t = len2 > 0 ? std::min(std::max(((x - p2x) * dx + (y - p2y) * dy) / len2, 0.0), 1.0) : 0.0;
            double ex = x - (p2x + dx * t), ey = y - (p2y + dy * t);
            double dist = std::sqrt(ex * ex + ey * ey);
            if (!(dist <= r)) continue;
            double lo;
            if (!c.offset(dist, lo) || !(lo < c.length)) continue;
            size_t i = (size_t)row * g.cols + col;
            if (sign > 0) addUncovered(g, i, (float)(wlo + lo), (float)(whi + c.length));
            else addUncovered(g, i, (float)(wlo - c.length), (float)(whi - lo));
        }
}

static void sweepAcross(DexelGrid& g, const double* p, const double* q, int k, int j, double sign, const Cutter& c) {
    int a, b;
    plane(k, a, b);
    int m = a == j ? b : a;
    double cell = g.cell, r = c.radius;
    double jlo, jhi;
    if (sign > 0) { jlo = std::max(p[j], q[j]) + c.start; jhi = std::min(p[j], q[j]) + c.crossLength; }
    else { jlo = std::max(p[j], q[j]) - c.crossLength; jhi = std::min(p[j], q[j]) - c.start; }
    if (!(jhi > jlo)) return;
    int jIndex = a == j ? 0 : 1;
    double jOrigin = jIndex == 0 ? g.originX : g.originY, mOrigin = jIndex == 0 ? g.originY : g.originX;
    int jCount = jIndex == 0 ? g.cols : g.rows, mCount = jIndex == 0 ? g.rows : g.cols;
    int j0 = std::max(0, (int)std::ceil((jlo - jOrigin) / cell)), j1 = std::min(jCount - 1, (int)std::floor((jhi - jOrigin) / cell));
    double mlo = std::min(p[m], q[m]) - r, mhi = std::max(p[m], q[m]) + r;
    int m0 = std::max(0, (int)std::floor((mlo - mOrigin) / cell)), m1 = std::min(mCount - 1, (int)std::ceil((mhi - mOrigin) / cell));
    if (j0 > j1 || m0 > m1) return;
    for (int mi = m0; mi <= m1; ++mi) {
        double cm = mOrigin + mi * cell, lo, hi;
        if (!capsule(p[k], p[m], q[k], q[m], r, cm, lo, hi)) continue;
        for (int ji = j0; ji <= j1; ++ji) {
            size_t index = jIndex == 0 ? (size_t)mi * g.cols + ji : (size_t)ji * g.cols + mi;
            addUncovered(g, index, (float)lo, (float)hi);
        }
    }
}

class StockModel {
public:
    double sx, sy, sz, cell;
    std::vector<DexelGrid> removed, part;

    StockModel(double sx_, double sy_, double sz_, double cell_,
               py::array_t<float, py::array::c_style | py::array::forcecast> vertices,
               py::array_t<uint32_t, py::array::c_style | py::array::forcecast> indices)
        : sx(sx_), sy(sy_), sz(sz_), cell(cell_) {
        double lo[3] = {-sx / 2, -sy / 2, -sz}, hi[3] = {sx / 2, sy / 2, 0};
        auto v = vertices.unchecked<1>();
        for (int k = 0; k < 3; ++k) {
            int a, b;
            plane(k, a, b);
            DexelGrid g(lo[a], lo[b], hi[a], hi[b], cell);
            removed.push_back(g);
            py::array_t<float> turned(v.shape(0));
            auto t = turned.mutable_unchecked<1>();
            for (py::ssize_t i = 0; i + 2 < v.shape(0); i += 3) {
                float pt[3] = {v(i), v(i + 1), v(i + 2)};
                t(i) = pt[a]; t(i + 1) = pt[b]; t(i + 2) = pt[k];
            }
            DexelGrid f = g;
            f.fill(turned, indices);
            part.push_back(f);
        }
    }

    void spanOf(int k, double& lo, double& hi) const {
        if (k == 0) { lo = -sx / 2; hi = sx / 2; } else if (k == 1) { lo = -sy / 2; hi = sy / 2; } else { lo = -sz; hi = 0; }
    }

    // Pieces (N×6: a, b in side A's frame) swept into the three grids.
    void sweep(py::array_t<double, py::array::c_style | py::array::forcecast> pieces, int j, double sign, const Cutter& c) {
        auto P = pieces.unchecked<2>();
        py::ssize_t n = P.shape(0);
        std::vector<double> data((size_t)n * 6);
        for (py::ssize_t i = 0; i < n; ++i)
            for (int k = 0; k < 6; ++k) data[(size_t)i * 6 + k] = P(i, k);
        py::gil_scoped_release release;
        for (int k = 0; k < 3; ++k)
            for (py::ssize_t i = 0; i < n; ++i) {
                const double* p = &data[(size_t)i * 6];
                if (k == j) sweepAlong(removed[k], p, p + 3, j, sign, c);
                else sweepAcross(removed[k], p, p + 3, k, j, sign, c);
            }
    }

    bool excess(int k, size_t i, double w0, double w1, double tol) const {
        double slo, shi;
        spanOf(k, slo, shi);
        double lo = std::max(w0, slo), hi = std::min(w1, shi);
        if (!(hi - lo > tol)) return false;
        const auto& A = part[k].spans[i];
        const auto& B = removed[k].spans[i];
        size_t ia = 0, ib = 0;
        double cursor = lo;
        while (cursor < hi - tol) {
            Span next;
            if (ia < A.size() && ib < B.size()) { if (A[ia].lo <= B[ib].lo) next = A[ia++]; else next = B[ib++]; }
            else if (ia < A.size()) next = A[ia++];
            else if (ib < B.size()) next = B[ib++];
            else return true;
            double x = next.lo, y = next.hi;
            if (y <= cursor) continue;
            if (x > cursor + tol) return x - cursor > tol;
            cursor = std::max(cursor, y);
        }
        return false;
    }

    bool meetsExcess(const double* p, int j, double sign, const Cutter& c, double tol) const {
        double r = c.radius;
        double w0 = sign > 0 ? p[j] : p[j] - c.length, w1 = sign > 0 ? p[j] + c.length : p[j];
        {
            int a, b;
            plane(j, a, b);
            const DexelGrid& g = removed[j];
            int c0 = std::max(0, (int)std::floor((p[a] - r - g.originX) / cell)), c1 = std::min(g.cols - 1, (int)std::ceil((p[a] + r - g.originX) / cell));
            int r0 = std::max(0, (int)std::floor((p[b] - r - g.originY) / cell)), r1 = std::min(g.rows - 1, (int)std::ceil((p[b] + r - g.originY) / cell));
            if (c0 <= c1 && r0 <= r1)
                for (int row = r0; row <= r1; ++row)
                    for (int col = c0; col <= c1; ++col) {
                        double x = g.originX + col * cell - p[a], y = g.originY + row * cell - p[b];
                        if (!(std::sqrt(x * x + y * y) <= r + cell * 0.5)) continue;
                        if (excess(j, (size_t)row * g.cols + col, w0, w1, tol)) return true;
                    }
        }
        for (int k = 0; k < 3; ++k) {
            if (k == j) continue;
            int a, b;
            plane(k, a, b);
            int m = a == j ? b : a;
            const DexelGrid& g = removed[k];
            int jIndex = a == j ? 0 : 1;
            double jOrigin = jIndex == 0 ? g.originX : g.originY, mOrigin = jIndex == 0 ? g.originY : g.originX;
            int jCount = jIndex == 0 ? g.cols : g.rows, mCount = jIndex == 0 ? g.rows : g.cols;
            int j0 = std::max(0, (int)std::floor((w0 - jOrigin) / cell)), j1 = std::min(jCount - 1, (int)std::ceil((w1 - jOrigin) / cell));
            int m0 = std::max(0, (int)std::floor((p[m] - r - mOrigin) / cell)), m1 = std::min(mCount - 1, (int)std::ceil((p[m] + r - mOrigin) / cell));
            if (j0 > j1 || m0 > m1) continue;
            for (int mi = m0; mi <= m1; ++mi) {
                double dm = mOrigin + mi * cell - p[m];
                if (!(std::abs(dm) <= r)) continue;
                double w = std::sqrt(r * r - dm * dm);
                for (int ji = j0; ji <= j1; ++ji) {
                    size_t index = jIndex == 0 ? (size_t)mi * g.cols + ji : (size_t)ji * g.cols + mi;
                    if (excess(k, index, p[k] - w, p[k] + w, tol)) return true;
                }
            }
        }
        return false;
    }

    py::array_t<bool> meetsExcessBatch(py::array_t<double, py::array::c_style | py::array::forcecast> points, int j, double sign,
                                       const Cutter& c, double tol) const {
        auto P = points.unchecked<2>();
        py::ssize_t n = P.shape(0);
        std::vector<double> data((size_t)n * 3);
        for (py::ssize_t i = 0; i < n; ++i)
            for (int k = 0; k < 3; ++k) data[(size_t)i * 3 + k] = P(i, k);
        std::vector<char> hit((size_t)n, 0);
        {
            py::gil_scoped_release release;
            for (py::ssize_t i = 0; i < n; ++i) hit[(size_t)i] = meetsExcess(&data[(size_t)i * 3], j, sign, c, tol) ? 1 : 0;
        }
        py::array_t<bool> out(n);
        auto o = out.mutable_unchecked<1>();
        for (py::ssize_t i = 0; i < n; ++i) o(i) = hit[(size_t)i] != 0;
        return out;
    }

    DexelGrid material(int k) const {
        DexelGrid g = removed[k];
        double slo, shi;
        spanOf(k, slo, shi);
        float s_lo = (float)slo, s_hi = (float)shi;
        for (size_t i = 0; i < g.spans.size(); ++i) {
            std::vector<Span> out;
            float cursor = s_lo;
            for (const auto& v : removed[k].spans[i]) {
                if (!(v.hi > cursor)) continue;
                if (v.lo > cursor) out.push_back({cursor, std::min(v.lo, s_hi)});
                cursor = std::max(cursor, v.hi);
                if (cursor >= s_hi) break;
            }
            if (cursor < s_hi) out.push_back({cursor, s_hi});
            std::vector<Span> kept;
            for (const auto& s : out) if (s.hi - s.lo > 0.01f) kept.push_back(s);
            g.spans[i] = std::move(kept);
        }
        return g;
    }

    py::list materialAlong(int k, double px, double py, double pz) const {
        double p[3] = {px, py, pz};
        int a, b;
        plane(k, a, b);
        const DexelGrid& g = removed[k];
        int col = (int)std::lround((p[a] - g.originX) / cell), row = (int)std::lround((p[b] - g.originY) / cell);
        py::list out;
        if (col < 0 || row < 0 || col >= g.cols || row >= g.rows) return out;
        double slo, shi;
        spanOf(k, slo, shi);
        float cursor = (float)slo, s_hi = (float)shi;
        std::vector<Span> spans;
        for (const auto& v : g.spans[(size_t)row * g.cols + col]) {
            if (!(v.hi > cursor)) continue;
            if (v.lo > cursor) spans.push_back({cursor, std::min(v.lo, s_hi)});
            cursor = std::max(cursor, v.hi);
        }
        if (cursor < s_hi) spans.push_back({cursor, s_hi});
        for (const auto& s : spans) if (s.hi - s.lo > 0.01f) out.append(py::make_tuple(s.lo, s.hi));
        return out;
    }
};

// A closed mesh of a dexel grid's spans along axis k (DexelMesher.swift).
static py::tuple dexelMesh(const DexelGrid& g, int k) {
    std::vector<float> P, N;
    std::vector<uint32_t> T;
    int a, b;
    plane(k, a, b);
    float h = (float)(g.cell / 2);
    auto point = [&](float u, float v, float w, float* q) { q[0] = q[1] = q[2] = 0; q[a] = u; q[b] = v; q[k] = w; };
    auto quad = [&](const float* c0, const float* c1, const float* c2, const float* c3, const float* n) {
        float e1[3] = {c1[0] - c0[0], c1[1] - c0[1], c1[2] - c0[2]}, e2[3] = {c2[0] - c0[0], c2[1] - c0[1], c2[2] - c0[2]};
        float cr[3] = {e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]};
        bool flip = cr[0] * n[0] + cr[1] * n[1] + cr[2] * n[2] < 0;
        uint32_t base = (uint32_t)(P.size() / 3);
        const float* order[4] = {c0, c1, c2, c3};
        if (flip) { order[1] = c3; order[3] = c1; }
        for (int i = 0; i < 4; ++i) { P.insert(P.end(), {order[i][0], order[i][1], order[i][2]}); N.insert(N.end(), {n[0], n[1], n[2]}); }
        T.insert(T.end(), {base, base + 1, base + 2, base, base + 2, base + 3});
    };
    static const std::vector<Span> none;
    auto spans = [&](int c, int r) -> const std::vector<Span>& {
        if (c < 0 || r < 0 || c >= g.cols || r >= g.rows) return none;
        return g.spans[(size_t)r * g.cols + c];
    };
    auto minus = [](const std::vector<Span>& mine, const std::vector<Span>& other) {
        std::vector<Span> out;
        for (const auto& s : mine) {
            float cursor = s.lo;
            for (const auto& o : other) {
                if (!(o.hi > cursor && o.lo < s.hi)) continue;
                if (o.lo > cursor) out.push_back({cursor, o.lo});
                cursor = std::max(cursor, o.hi);
            }
            if (cursor < s.hi) out.push_back({cursor, s.hi});
        }
        std::vector<Span> kept;
        for (const auto& s : out) if (s.hi - s.lo > 0.005f) kept.push_back(s);
        return kept;
    };
    auto same = [](const std::vector<Span>& x, const std::vector<Span>& y) {
        if (x.size() != y.size()) return false;
        for (size_t i = 0; i < x.size(); ++i) if (x[i].lo != y[i].lo || x[i].hi != y[i].hi) return false;
        return true;
    };
    float axisK[2][3] = {{0, 0, 0}, {0, 0, 0}}, axisA[2][3] = {{0, 0, 0}, {0, 0, 0}}, axisB[2][3] = {{0, 0, 0}, {0, 0, 0}};
    axisK[0][k] = 1; axisK[1][k] = -1; axisA[0][a] = 1; axisA[1][a] = -1; axisB[0][b] = 1; axisB[1][b] = -1;
    float q0[3], q1[3], q2[3], q3[3];
    for (int r = 0; r < g.rows; ++r) {
        int c = 0;
        while (c < g.cols) {
            const auto& mine = spans(c, r);
            int e = c;
            while (e + 1 < g.cols && same(spans(e + 1, r), mine)) ++e;
            if (!mine.empty()) {
                float u0 = (float)(g.originX + c * g.cell) - h, u1 = (float)(g.originX + e * g.cell) + h;
                float v0 = (float)(g.originY + r * g.cell) - h, v1 = v0 + 2 * h;
                for (const auto& s : mine) {
                    point(u0, v0, s.hi, q0); point(u1, v0, s.hi, q1); point(u1, v1, s.hi, q2); point(u0, v1, s.hi, q3);
                    quad(q0, q1, q2, q3, axisK[0]);
                    point(u0, v0, s.lo, q0); point(u1, v0, s.lo, q1); point(u1, v1, s.lo, q2); point(u0, v1, s.lo, q3);
                    quad(q0, q1, q2, q3, axisK[1]);
                }
                for (int cc = c; cc <= e; ++cc) {
                    float x = (float)(g.originX + cc * g.cell), y = (float)(g.originY + r * g.cell);
                    float a0 = x - h, a1 = x + h, b0 = y - h, b1 = y + h;
                    if (cc == c)
                        for (const auto& s : minus(mine, spans(cc - 1, r))) {
                            point(a0, b0, s.lo, q0); point(a0, b1, s.lo, q1); point(a0, b1, s.hi, q2); point(a0, b0, s.hi, q3);
                            quad(q0, q1, q2, q3, axisA[1]);
                        }
                    if (cc == e)
                        for (const auto& s : minus(mine, spans(cc + 1, r))) {
                            point(a1, b0, s.lo, q0); point(a1, b1, s.lo, q1); point(a1, b1, s.hi, q2); point(a1, b0, s.hi, q3);
                            quad(q0, q1, q2, q3, axisA[0]);
                        }
                    for (const auto& s : minus(mine, spans(cc, r - 1))) {
                        point(a0, b0, s.lo, q0); point(a1, b0, s.lo, q1); point(a1, b0, s.hi, q2); point(a0, b0, s.hi, q3);
                        quad(q0, q1, q2, q3, axisB[1]);
                    }
                    for (const auto& s : minus(mine, spans(cc, r + 1))) {
                        point(a0, b1, s.lo, q0); point(a1, b1, s.lo, q1); point(a1, b1, s.hi, q2); point(a0, b1, s.hi, q3);
                        quad(q0, q1, q2, q3, axisB[0]);
                    }
                }
            }
            c = e + 1;
        }
    }
    py::array_t<float> pa({(py::ssize_t)(P.size() / 3), (py::ssize_t)3});
    py::array_t<float> na({(py::ssize_t)(N.size() / 3), (py::ssize_t)3});
    py::array_t<uint32_t> ta((py::ssize_t)T.size());
    std::copy(P.begin(), P.end(), pa.mutable_data());
    std::copy(N.begin(), N.end(), na.mutable_data());
    std::copy(T.begin(), T.end(), ta.mutable_data());
    return py::make_tuple(pa, na, ta);
}

// ---------------------------------------------------------------- heightmap (Heightmap.swift)

class Heightmap {
public:
    double originX, originY, cell, top, bottom;
    int cols, rows;
    py::array_t<float> heights;
    bool hasDirty = false;
    int d0 = 0, d1 = 0, d2 = 0, d3 = 0;

    Heightmap(double minX, double minY, double minZ, double maxX, double maxY, double maxZ, int maxCells) {
        double w = maxX - minX, h = maxY - minY;
        double c = std::max(std::sqrt(w * h / (double)maxCells), 0.05);
        cell = c;
        cols = std::max((int)std::ceil(w / c), 2);
        rows = std::max((int)std::ceil(h / c), 2);
        originX = minX + c / 2;
        originY = minY + c / 2;
        top = maxZ;
        bottom = minZ;
        heights = py::array_t<float>({(py::ssize_t)rows, (py::ssize_t)cols});
        std::fill(heights.mutable_data(), heights.mutable_data() + (size_t)rows * cols, (float)maxZ);
    }

    void cut(double ax, double ay, double az, double bx, double by, double bz, double r, double rc) {
        if (az >= top && bz >= top) return;
        double minX = std::min(ax, bx) - r, maxX = std::max(ax, bx) + r, minY = std::min(ay, by) - r, maxY = std::max(ay, by) + r;
        int c0 = std::max((int)std::floor((minX - originX) / cell), 0), c1 = std::min((int)std::ceil((maxX - originX) / cell), cols - 1);
        int r0 = std::max((int)std::floor((minY - originY) / cell), 0), r1 = std::min((int)std::ceil((maxY - originY) / cell), rows - 1);
        if (c0 > c1 || r0 > r1) return;
        double dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy;
        rc = std::min(std::max(rc, 0.0), r);
        double flatR = r - rc;
        bool changed = false;
        float floorZ = (float)std::max(std::min(az, bz), bottom);
        float* H = heights.mutable_data();
        for (int row = r0; row <= r1; ++row) {
            double y = originY + row * cell;
            int lo = c0, hi = c1;
            if (std::abs(dy) > 1e-9) {
                double ta = std::min(std::max((y - r - ay) / dy, 0.0), 1.0), tb = std::min(std::max((y + r - ay) / dy, 0.0), 1.0);
                double xa = ax + dx * ta, xb = ax + dx * tb;
                lo = std::max(c0, (int)std::floor((std::min(xa, xb) - r - originX) / cell));
                hi = std::min(c1, (int)std::ceil((std::max(xa, xb) + r - originX) / cell));
                if (lo > hi) continue;
            }
            size_t rowBase = (size_t)row * cols;
            for (int col = lo; col <= hi; ++col) {
                if (H[rowBase + col] <= floorZ) continue;
                double x = originX + col * cell;
                double t = 0;
                if (len2 > 1e-12) t = std::min(std::max(((x - ax) * dx + (y - ay) * dy) / len2, 0.0), 1.0);
                double px = ax + dx * t, py = ay + dy * t;
                double dist = std::sqrt((x - px) * (x - px) + (y - py) * (y - py));
                if (!(dist <= r)) continue;
                double z = az + (bz - az) * t;
                if (dist > flatR) {
                    double u = dist - flatR;
                    z += rc - std::sqrt(std::max(rc * rc - u * u, 0.0));
                }
                float zf = (float)std::max(z, bottom);
                if (zf < H[rowBase + col]) { H[rowBase + col] = zf; changed = true; }
            }
        }
        if (changed) {
            if (hasDirty) { d0 = std::min(d0, c0); d1 = std::min(d1, r0); d2 = std::max(d2, c1); d3 = std::max(d3, r1); }
            else { hasDirty = true; d0 = c0; d1 = r0; d2 = c1; d3 = r1; }
        }
    }

    void cutPath(py::array_t<double, py::array::c_style | py::array::forcecast> points, double r, double rc) {
        auto p = points.unchecked<2>();
        for (py::ssize_t i = 1; i < p.shape(0); ++i) cut(p(i - 1, 0), p(i - 1, 1), p(i - 1, 2), p(i, 0), p(i, 1), p(i, 2), r, rc);
    }

    void markAllDirty() { hasDirty = true; d0 = 0; d1 = 0; d2 = cols - 1; d3 = rows - 1; }

    py::object takeDirty() {
        if (!hasDirty) return py::none();
        hasDirty = false;
        return py::make_tuple(d0, d1, d2, d3);
    }

    double removedVolume() const {
        const float* H = heights.data();
        double total = 0;
        for (size_t i = 0; i < (size_t)rows * cols; ++i) total += top - (double)H[i];
        return total * cell * cell;
    }
};


// ---------------------------------------------------------------- fixture field (FixtureClearance.swift)

#include <map>

class FixtureField {
public:
    double minX, minY, cell;
    int nx, ny;
    std::vector<float> top;
    std::map<long long, std::vector<float>> dilatedCache;

    FixtureField(py::array_t<double, py::array::c_style | py::array::forcecast> triangles,
                 double rminX, double rminY, double rmaxX, double rmaxY, double cell_)
        : minX(rminX), minY(rminY), cell(cell_) {
        nx = std::max((int)std::ceil((rmaxX - rminX) / cell) + 1, 1);
        ny = std::max((int)std::ceil((rmaxY - rminY) / cell) + 1, 1);
        top.assign((size_t)nx * ny, -INFINITY);
        auto t = triangles.unchecked<2>();
        auto put = [&](double x, double y, double z) {
            long i = std::lround((x - minX) / cell), j = std::lround((y - minY) / cell);
            if (i < 0 || j < 0 || i >= nx || j >= ny) return;
            float& v = top[(size_t)j * nx + i];
            v = std::max(v, (float)z);
        };
        py::ssize_t n3 = t.shape(0);
        for (py::ssize_t k = 0; k + 2 < n3; k += 3) {
            double a[3] = {t(k, 0), t(k, 1), t(k, 2)}, b[3] = {t(k + 1, 0), t(k + 1, 1), t(k + 1, 2)}, c[3] = {t(k + 2, 0), t(k + 2, 1), t(k + 2, 2)};
            double lox = std::min({a[0], b[0], c[0]}), hix = std::max({a[0], b[0], c[0]});
            double loy = std::min({a[1], b[1], c[1]}), hiy = std::max({a[1], b[1], c[1]});
            if (hix < rminX - cell || lox > rmaxX + cell || hiy < rminY - cell || loy > rmaxY + cell) continue;
            auto len = [](const double* p, const double* q) { double x = q[0] - p[0], y = q[1] - p[1], z = q[2] - p[2]; return std::sqrt(x * x + y * y + z * z); };
            double longest = std::max({len(a, b), len(a, c), len(b, c)});
            int n = std::max((int)std::ceil(longest / (cell * 0.7)), 1);
            for (int u = 0; u <= n; ++u)
                for (int v = 0; v <= n - u; ++v) {
                    double fu = (double)u / n, fv = (double)v / n;
                    put(a[0] + (b[0] - a[0]) * fu + (c[0] - a[0]) * fv, a[1] + (b[1] - a[1]) * fu + (c[1] - a[1]) * fv,
                        a[2] + (b[2] - a[2]) * fu + (c[2] - a[2]) * fv);
                }
        }
    }

    bool empty() const {
        for (float v : top) if (v > -INFINITY) return false;
        return true;
    }

    const std::vector<float>& dilated(double radius) {
        int k = std::max((int)std::floor(radius / cell), 0);
        long long key = std::llround(radius * 1000);
        auto it = dilatedCache.find(key);
        if (it != dilatedCache.end()) return it->second;
        std::map<int, std::vector<float>> rowMax;
        auto rows = [&](int w) -> const std::vector<float>& {
            auto found = rowMax.find(w);
            if (found != rowMax.end()) return found->second;
            std::vector<float> out((size_t)nx * ny, -INFINITY);
            for (int j = 0; j < ny; ++j) {
                size_t base = (size_t)j * nx;
                for (int i = 0; i < nx; ++i) {
                    float m = -INFINITY;
                    for (int di = std::max(i - w, 0); di <= std::min(i + w, nx - 1); ++di) m = std::max(m, top[base + di]);
                    out[base + i] = m;
                }
            }
            return rowMax.emplace(w, std::move(out)).first->second;
        };
        std::vector<float> out((size_t)nx * ny, -INFINITY);
        for (int dj = -k; dj <= k; ++dj) {
            int w = (int)(std::sqrt(std::max(radius * radius - (double)(dj * dj) * cell * cell, 0.0)) / cell);
            const auto& r = rows(w);
            for (int j = std::max(-dj, 0); j < std::min(ny, ny - dj); ++j) {
                size_t src = (size_t)(j + dj) * nx, dst = (size_t)j * nx;
                for (int i = 0; i < nx; ++i) if (r[src + i] > out[dst + i]) out[dst + i] = r[src + i];
            }
        }
        return dilatedCache.emplace(key, std::move(out)).first->second;
    }

    float value(const std::vector<float>& d, double x, double y) const {
        long i = std::lround((x - minX) / cell), j = std::lround((y - minY) / cell);
        if (i < 0 || j < 0 || i >= nx || j >= ny) return -INFINITY;
        return d[(size_t)j * nx + i];
    }

    // For each point (N×3 tool tips) and section (z0, radius): the intrusion f − (z + z0) + margin
    // into the dilated field (−inf where no fixture). Returns an (N × sections) array.
    py::array_t<double> intrusions(py::array_t<double, py::array::c_style | py::array::forcecast> points,
                                   std::vector<double> z0s, std::vector<double> radii, double margin) {
        auto P = points.unchecked<2>();
        size_t n = (size_t)P.shape(0), s = z0s.size();
        std::vector<const std::vector<float>*> maps;
        double snap = cell * 0.71;
        for (double r : radii) maps.push_back(&dilated(std::max(r + margin - snap, 0.0)));
        py::array_t<double> out({(py::ssize_t)n, (py::ssize_t)s});
        auto o = out.mutable_unchecked<2>();
        for (size_t i = 0; i < n; ++i)
            for (size_t k = 0; k < s; ++k) {
                float f = value(*maps[k], P(i, 0), P(i, 1));
                o(i, k) = f > -INFINITY ? (double)f - (P(i, 2) + z0s[k]) + margin : -INFINITY;
            }
        return out;
    }

    py::array_t<float> topArray() const {
        py::array_t<float> out({(py::ssize_t)ny, (py::ssize_t)nx});
        std::copy(top.begin(), top.end(), out.mutable_data());
        return out;
    }
};


// ---------------------------------------------------------------- collision (Collision.swift)

#include <array>
#include <set>
#include <tuple>
#include <unordered_map>

struct V3 {
    double x, y, z;
    V3 operator+(const V3& o) const { return {x + o.x, y + o.y, z + o.z}; }
    V3 operator-(const V3& o) const { return {x - o.x, y - o.y, z - o.z}; }
    V3 operator*(double k) const { return {x * k, y * k, z * k}; }
    V3 operator/(double k) const { return {x / k, y / k, z / k}; }
    double operator[](int k) const { return k == 0 ? x : k == 1 ? y : z; }
};
static inline double dot(const V3& a, const V3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static inline V3 cross(const V3& a, const V3& b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
static inline double len(const V3& a) { return std::sqrt(dot(a, a)); }
static inline V3 vmin(const V3& a, const V3& b) { return {std::min(a.x, b.x), std::min(a.y, b.y), std::min(a.z, b.z)}; }
static inline V3 vmax(const V3& a, const V3& b) { return {std::max(a.x, b.x), std::max(a.y, b.y), std::max(a.z, b.z)}; }

// Two triangles: do they pass through each other (not just touch)? The overlap's ends.
static bool triTri(const V3& a0, const V3& a1, const V3& a2, const V3& b0, const V3& b1, const V3& b2, double tol, V3& p, V3& q) {
    V3 nb = cross(b1 - b0, b2 - b0);
    double lb = len(nb);
    if (!(lb > 1e-12)) return false;
    V3 ub = nb / lb;
    double da[3] = {dot(a0 - b0, ub), dot(a1 - b0, ub), dot(a2 - b0, ub)};
    double penA = std::min(std::max({da[0], da[1], da[2]}), -std::min({da[0], da[1], da[2]}));
    if (!(penA > tol)) return false;
    V3 na = cross(a1 - a0, a2 - a0);
    double la = len(na);
    if (!(la > 1e-12)) return false;
    V3 ua = na / la;
    double db[3] = {dot(b0 - a0, ua), dot(b1 - a0, ua), dot(b2 - a0, ua)};
    double penB = std::min(std::max({db[0], db[1], db[2]}), -std::min({db[0], db[1], db[2]}));
    if (!(penB > tol)) return false;
    V3 dir = cross(ua, ub);
    if (!(dot(dir, dir) > 1e-12)) return false;
    auto crossing = [](const V3* P, const double* d, V3& s0, V3& s1) {
        V3 pts[3];
        int n = 0;
        const int I[3] = {0, 1, 2}, J[3] = {1, 2, 0};
        for (int k = 0; k < 3; ++k) {
            int i = I[k], j = J[k];
            if ((d[i] > 0) != (d[j] > 0)) pts[n++] = P[i] + (P[j] - P[i]) * (d[i] / (d[i] - d[j]));
        }
        if (n < 2) return false;
        s0 = pts[0];
        s1 = pts[1];
        return true;
    };
    V3 A[3] = {a0, a1, a2}, B[3] = {b0, b1, b2}, sa0, sa1, sb0, sb1;
    if (!crossing(A, da, sa0, sa1) || !crossing(B, db, sb0, sb1)) return false;
    double ta0 = dot(sa0, dir), ta1 = dot(sa1, dir), tb0 = dot(sb0, dir), tb1 = dot(sb1, dir);
    double lo = std::max(std::min(ta0, ta1), std::min(tb0, tb1)), hi = std::min(std::max(ta0, ta1), std::max(tb0, tb1));
    double scale = len(dir);
    if (!((hi - lo) / scale > tol)) return false;
    double span = ta1 - ta0;
    auto at = [&](double x) { return sa0 + (sa1 - sa0) * (std::abs(span) > 1e-12 ? (x - ta0) / span : 0.5); };
    p = at(lo);
    q = at(hi);
    return true;
}

class TriangleTree {
public:
    struct Node { V3 lo, hi; int left, start, count; };
    std::vector<V3> v;
    std::vector<Node> nodes;

    explicit TriangleTree(py::array_t<double, py::array::c_style | py::array::forcecast> triangles) {
        auto t = triangles.unchecked<2>();
        int n = (int)(t.shape(0) / 3);
        std::vector<V3> tri((size_t)n * 3);
        for (int i = 0; i < n * 3; ++i) tri[(size_t)i] = {t(i, 0), t(i, 1), t(i, 2)};
        std::vector<int> order(n);
        std::vector<V3> cen(n), tlo(n), thi(n);
        for (int k = 0; k < n; ++k) {
            order[k] = k;
            V3 a = tri[3 * k], b = tri[3 * k + 1], c = tri[3 * k + 2];
            cen[k] = (a + b + c) / 3;
            tlo[k] = vmin(a, vmin(b, c));
            thi[k] = vmax(a, vmax(b, c));
        }
        auto bounds = [&](int s, int e) {
            V3 lo{INFINITY, INFINITY, INFINITY}, hi{-INFINITY, -INFINITY, -INFINITY};
            for (int k = s; k < e; ++k) { lo = vmin(lo, tlo[order[k]]); hi = vmax(hi, thi[order[k]]); }
            return Node{lo, hi, -1, s, e - s};
        };
        std::vector<int> pending;
        if (n > 0) { nodes.push_back(bounds(0, n)); pending.push_back(0); }
        // Depth-first like the Swift recursion: split a node, then its left child, then its right.
        std::vector<int> stack = {0};
        if (n > 0) {
            std::function<void(int)> split = [&](int idx) {
                int s = nodes[idx].start, e = s + nodes[idx].count;
                if (e - s <= 6) return;
                V3 clo{INFINITY, INFINITY, INFINITY}, chi{-INFINITY, -INFINITY, -INFINITY};
                for (int k = s; k < e; ++k) { clo = vmin(clo, cen[order[k]]); chi = vmax(chi, cen[order[k]]); }
                V3 ext = chi - clo;
                int axis = (ext.x >= ext.y && ext.x >= ext.z) ? 0 : (ext.y >= ext.z ? 1 : 2);
                std::stable_sort(order.begin() + s, order.begin() + e, [&](int a, int b) { return cen[a][axis] < cen[b][axis]; });
                int mid = (s + e) / 2;
                int l = (int)nodes.size();
                nodes.push_back(bounds(s, mid));
                nodes.push_back(bounds(mid, e));
                nodes[idx].left = l;
                split(l);
                split(l + 1);
            };
            split(0);
        }
        v.reserve((size_t)n * 3);
        for (int k : order) { v.push_back(tri[3 * k]); v.push_back(tri[3 * k + 1]); v.push_back(tri[3 * k + 2]); }
    }

    int triangleCount() const { return (int)(v.size() / 3); }

    py::object boundsPy() const {
        if (nodes.empty()) return py::none();
        const Node& r = nodes[0];
        return py::make_tuple(py::make_tuple(r.lo.x, r.lo.y, r.lo.z), py::make_tuple(r.hi.x, r.hi.y, r.hi.z));
    }

    static bool overlap(const Node& a, const Node& b, double tol) {
        return a.lo.x <= b.hi.x - tol && a.lo.y <= b.hi.y - tol && a.lo.z <= b.hi.z - tol
            && b.lo.x <= a.hi.x - tol && b.lo.y <= a.hi.y - tol && b.lo.z <= a.hi.z - tol;
    }
    static double volume(const Node& n) { V3 e = n.hi - n.lo; return e.x * e.y * e.z; }

    bool contains(const V3& p) const {
        if (nodes.empty()) return false;
        const Node& root = nodes[0];
        if (!(p.x > root.lo.x && p.y > root.lo.y && p.z > root.lo.z && p.x < root.hi.x && p.y < root.hi.y && p.z < root.hi.z)) return false;
        V3 d0{0.5773 + 0.013, 0.5774 - 0.007, 0.5775 + 0.003};
        V3 d = d0 / len(d0);
        int crossings = 0;
        std::vector<int> stack = {0};
        while (!stack.empty()) {
            int i = stack.back(); stack.pop_back();
            const Node& n = nodes[i];
            double t0 = 0, t1 = INFINITY;
            for (int k = 0; k < 3; ++k) {
                double inv = 1 / d[k];
                double a = (n.lo[k] - p[k]) * inv, b = (n.hi[k] - p[k]) * inv;
                if (a > b) std::swap(a, b);
                t0 = std::max(t0, a); t1 = std::min(t1, b);
            }
            if (!(t0 <= t1)) continue;
            if (n.left >= 0) { stack.push_back(n.left); stack.push_back(n.left + 1); continue; }
            for (int t = n.start; t < n.start + n.count; ++t) {
                V3 a = v[3 * t], e1 = v[3 * t + 1] - a, e2 = v[3 * t + 2] - a;
                V3 h = cross(d, e2);
                double det = dot(e1, h);
                if (!(std::abs(det) > 1e-14)) continue;
                double f = 1 / det;
                V3 sv = p - a;
                double u = f * dot(sv, h);
                if (!(u >= 0 && u <= 1)) continue;
                V3 q = cross(sv, e1);
                double w = f * dot(d, q);
                if (!(w >= 0 && u + w <= 1)) continue;
                if (f * dot(e2, q) > 1e-9) ++crossings;
            }
        }
        return crossings % 2 == 1;
    }

    static double pointTriangle(const V3& p, const V3& a, const V3& b, const V3& c) {
        V3 ab = b - a, ac = c - a, ap = p - a;
        double d1 = dot(ab, ap), d2 = dot(ac, ap);
        if (d1 <= 0 && d2 <= 0) return len(ap);
        V3 bp = p - b;
        double d3 = dot(ab, bp), d4 = dot(ac, bp);
        if (d3 >= 0 && d4 <= d3) return len(bp);
        double vc = d1 * d4 - d3 * d2;
        if (vc <= 0 && d1 >= 0 && d3 <= 0) return len(p - (a + ab * (d1 / (d1 - d3))));
        V3 cp = p - c;
        double d5 = dot(ab, cp), d6 = dot(ac, cp);
        if (d6 >= 0 && d5 <= d6) return len(cp);
        double vb = d5 * d2 - d1 * d6;
        if (vb <= 0 && d2 >= 0 && d6 <= 0) return len(p - (a + ac * (d2 / (d2 - d6))));
        double va = d3 * d6 - d5 * d4;
        if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0) return len(p - (b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))));
        double den = 1 / (va + vb + vc);
        return len(p - (a + ab * (vb * den) + ac * (vc * den)));
    }

    double distance(const V3& p, double limit) const {
        double best = limit;
        if (nodes.empty()) return best;
        std::vector<int> stack = {0};
        while (!stack.empty()) {
            int i = stack.back(); stack.pop_back();
            const Node& n = nodes[i];
            V3 gap = vmax(vmax(n.lo - p, p - n.hi), V3{0, 0, 0});
            if (!(len(gap) < best)) continue;
            if (n.left >= 0) { stack.push_back(n.left); stack.push_back(n.left + 1); continue; }
            for (int t = n.start; t < n.start + n.count; ++t) best = std::min(best, pointTriangle(p, v[3 * t], v[3 * t + 1], v[3 * t + 2]));
        }
        return best;
    }

    py::object raycast(double px, double py, double pz, double dx, double dy, double dz) const {
        V3 p{px, py, pz}, d0{dx, dy, dz};
        V3 d = d0 / len(d0);
        double best = INFINITY;
        std::vector<int> stack;
        if (!nodes.empty()) stack.push_back(0);
        while (!stack.empty()) {
            int i = stack.back(); stack.pop_back();
            const Node& n = nodes[i];
            double t0 = 0, t1 = best;
            for (int k = 0; k < 3; ++k) {
                if (std::abs(d[k]) < 1e-15) {
                    if (p[k] < n.lo[k] || p[k] > n.hi[k]) { t0 = 1; t1 = 0; }
                    continue;
                }
                double inv = 1 / d[k];
                double a = (n.lo[k] - p[k]) * inv, b = (n.hi[k] - p[k]) * inv;
                if (a > b) std::swap(a, b);
                t0 = std::max(t0, a); t1 = std::min(t1, b);
            }
            if (!(t0 <= t1)) continue;
            if (n.left >= 0) { stack.push_back(n.left); stack.push_back(n.left + 1); continue; }
            for (int t = n.start; t < n.start + n.count; ++t) {
                V3 a = v[3 * t], e1 = v[3 * t + 1] - a, e2 = v[3 * t + 2] - a;
                V3 h = cross(d, e2);
                double det = dot(e1, h);
                if (!(std::abs(det) > 1e-14)) continue;
                double f = 1 / det;
                V3 sv = p - a;
                double u = f * dot(sv, h);
                if (!(u >= 0 && u <= 1)) continue;
                V3 q = cross(sv, e1);
                double w = f * dot(d, q);
                if (!(w >= 0 && u + w <= 1)) continue;
                double tt = f * dot(e2, q);
                if (tt > 1e-9 && tt < best) best = tt;
            }
        }
        if (std::isfinite(best)) return py::float_(best);
        return py::none();
    }

    std::pair<double, V3> insideDepth(const TriangleTree& other, const V3& blo, const V3& bhi) const {
        std::pair<double, V3> best{0.0, V3{0, 0, 0}};
        int seen = 0;
        for (const auto& p : other.v) {
            if (!(p.x >= blo.x && p.y >= blo.y && p.z >= blo.z && p.x <= bhi.x && p.y <= bhi.y && p.z <= bhi.z)) continue;
            if (++seen > 3000) break;
            if (contains(p)) {
                double d = distance(p, INFINITY);
                if (d > best.first) best = {d, p};
            }
        }
        return best;
    }

    static std::vector<std::vector<int>> clusters(const std::vector<std::pair<V3, V3>>& segs, double link) {
        struct Key { long x, y, z; bool operator==(const Key& o) const { return x == o.x && y == o.y && z == o.z; } };
        struct H { size_t operator()(const Key& k) const { return std::hash<long>()(k.x * 73856093L ^ k.y * 19349663L ^ k.z * 83492791L); } };
        auto cell = [&](const V3& p) { return Key{(long)std::floor(p.x / link), (long)std::floor(p.y / link), (long)std::floor(p.z / link)}; };
        std::unordered_map<Key, std::vector<int>, H> grid;
        for (size_t k = 0; k < segs.size(); ++k) {
            const auto& s = segs[k];
            int n = std::max((int)(len(s.second - s.first) / link), 1);
            for (int i = 0; i <= n; ++i) grid[cell(s.first + (s.second - s.first) * ((double)i / n))].push_back((int)k);
        }
        std::vector<int> label(segs.size(), -1);
        std::vector<std::vector<int>> out;
        for (size_t start = 0; start < segs.size(); ++start) {
            if (label[start] >= 0) continue;
            std::vector<int> group = {(int)start};
            label[start] = (int)out.size();
            size_t i = 0;
            while (i < group.size()) {
                const auto& s = segs[group[i]];
                ++i;
                int n = std::max((int)(len(s.second - s.first) / link), 1);
                std::unordered_map<Key, bool, H> seen;
                for (int j = 0; j <= n; ++j) {
                    Key c = cell(s.first + (s.second - s.first) * ((double)j / n));
                    for (long dx = -1; dx <= 1; ++dx) for (long dy = -1; dy <= 1; ++dy) for (long dz = -1; dz <= 1; ++dz) {
                        Key cc{c.x + dx, c.y + dy, c.z + dz};
                        if (seen.count(cc)) continue;
                        seen[cc] = true;
                        auto f = grid.find(cc);
                        if (f == grid.end()) continue;
                        for (int k : f->second) if (label[k] < 0) { label[k] = (int)out.size(); group.push_back(k); }
                    }
                }
            }
            out.push_back(group);
        }
        return out;
    }

    py::object intersect(const TriangleTree& other, double tolerance) const {
        if (nodes.empty() || other.nodes.empty() || !overlap(nodes[0], other.nodes[0], tolerance)) return py::none();
        std::vector<std::pair<V3, V3>> segs;
        int hits = 0;
        std::vector<std::pair<int, int>> stack = {{0, 0}};
        while (!stack.empty()) {
            auto [i, j] = stack.back(); stack.pop_back();
            const Node& na = nodes[i];
            const Node& nb = other.nodes[j];
            if (!overlap(na, nb, tolerance)) continue;
            if (na.left < 0 && nb.left < 0) {
                for (int ta = na.start; ta < na.start + na.count; ++ta)
                    for (int tb = nb.start; tb < nb.start + nb.count; ++tb) {
                        V3 p, q;
                        if (triTri(v[3 * ta], v[3 * ta + 1], v[3 * ta + 2], other.v[3 * tb], other.v[3 * tb + 1], other.v[3 * tb + 2], tolerance, p, q)) {
                            segs.push_back({p, q});
                            ++hits;
                        }
                    }
                if (hits > 20000) break;
            } else if (nb.left < 0 || (na.left >= 0 && volume(na) >= volume(nb))) {
                stack.push_back({na.left, j});
                stack.push_back({na.left + 1, j});
            } else {
                stack.push_back({i, nb.left});
                stack.push_back({i, nb.left + 1});
            }
        }
        if (hits == 0) return py::none();
        V3 blo = vmax(nodes[0].lo, other.nodes[0].lo), bhi = vmin(nodes[0].hi, other.nodes[0].hi);
        auto inA = insideDepth(other, blo, bhi), inB = other.insideDepth(*this, blo, bhi);
        auto inside = inA.first >= inB.first ? inA : inB;
        std::pair<double, V3> best{0.0, segs[0].first};
        for (const auto& c : clusters(segs, 1.0)) {
            V3 lo{INFINITY, INFINITY, INFINITY}, hi{-INFINITY, -INFINITY, -INFINITY};
            for (int k : c) { lo = vmin(lo, vmin(segs[k].first, segs[k].second)); hi = vmax(hi, vmax(segs[k].first, segs[k].second)); }
            double e[3] = {hi.x - lo.x, hi.y - lo.y, hi.z - lo.z};
            std::sort(e, e + 3);
            double d = (e[0] < 0.05 && inside.first == 0) ? e[1] : e[0];
            if (d >= best.first) best = {d, (lo + hi) / 2};
        }
        if (inside.first > best.first) best = inside;
        if (!(best.first > tolerance)) return py::none();
        return py::make_tuple(best.first, py::make_tuple(best.second.x, best.second.y, best.second.z));
    }

    bool touches(const TriangleTree& other, double ox, double oy, double oz, double tolerance) const {
        if (nodes.empty() || other.nodes.empty()) return false;
        V3 off{ox, oy, oz};
        std::vector<std::pair<int, int>> stack = {{0, 0}};
        while (!stack.empty()) {
            auto [i, j] = stack.back(); stack.pop_back();
            const Node& na = nodes[i];
            Node nb = other.nodes[j];
            nb.lo = nb.lo + off; nb.hi = nb.hi + off;
            if (!overlap(na, nb, tolerance)) continue;
            if (na.left < 0 && nb.left < 0) {
                for (int ta = na.start; ta < na.start + na.count; ++ta)
                    for (int tb = nb.start; tb < nb.start + nb.count; ++tb) {
                        V3 p, q;
                        if (triTri(v[3 * ta], v[3 * ta + 1], v[3 * ta + 2], other.v[3 * tb] + off, other.v[3 * tb + 1] + off,
                                   other.v[3 * tb + 2] + off, tolerance, p, q)) return true;
                    }
            } else if (nb.left < 0 || (na.left >= 0 && volume(na) >= volume(nb))) {
                stack.push_back({na.left, j});
                stack.push_back({na.left + 1, j});
            } else {
                stack.push_back({i, nb.left});
                stack.push_back({i, nb.left + 1});
            }
        }
        return false;
    }
};

PYBIND11_MODULE(_kernels, m) {
    m.doc() = "Coastline app kernels (DexelGrid)";
    py::enum_<ToolKind>(m, "ToolKind")
        .value("flat", ToolKind::flat).value("ball", ToolKind::ball)
        .value("drill", ToolKind::drill).value("disc", ToolKind::disc);
    py::class_<ToolShape>(m, "ToolShape")
        .def(py::init([](ToolKind kind, double radius, double length, double discThickness, double shankRadius) {
                 return ToolShape{kind, radius, length, discThickness, shankRadius};
             }),
             py::arg("kind"), py::arg("radius"), py::arg("length"), py::arg("disc_thickness") = 0.0, py::arg("shank_radius") = 0.0)
        .def("ranges", [](const ToolShape& t, double r) { double lo, hi; t.ranges(r, lo, hi); return py::make_tuple(lo, hi); });
    py::class_<DexelGrid>(m, "DexelGrid")
        .def(py::init<double, double, double, double, double>())
        .def_readonly("origin_x", &DexelGrid::originX)
        .def_readonly("origin_y", &DexelGrid::originY)
        .def_readonly("cell", &DexelGrid::cell)
        .def_readonly("cols", &DexelGrid::cols)
        .def_readonly("rows", &DexelGrid::rows)
        .def("copy", [](const DexelGrid& g) { return DexelGrid(g); })
        .def("add", &DexelGrid::add)
        .def("sweep", &DexelGrid::sweep)
        .def("sweep_path", &DexelGrid::sweepPath)
        .def("fill", &DexelGrid::fill)
        .def("intersection", &DexelGrid::intersection, py::arg("other"), py::arg("minimum") = 0.0f)
        .def("clipped", &DexelGrid::clipped)
        .def("subtracting", &DexelGrid::subtracting, py::arg("other"), py::arg("minimum") = 0.0f)
        .def("volume", &DexelGrid::volume)
        .def("empty", &DexelGrid::empty)
        .def("mesh", &DexelGrid::mesh)
        .def("spans", &DexelGrid::getSpans)
        .def("set_spans", &DexelGrid::setSpans)
        .def("any_in", &DexelGrid::anyIn)
        .def("flat", &DexelGrid::flat)
        .def("merge", &DexelGrid::merge)
        .def("covered", &DexelGrid::covered)
        .def("near", &DexelGrid::near);
    py::class_<Cutter>(m, "Cutter")
        .def(py::init([](int tip, double radius, double start, double length, double crossLength, double corner, double halfAngle) {
                 return Cutter{tip, radius, start, length, crossLength, corner, halfAngle};
             }))
        .def_readwrite("length", &Cutter::length)
        .def_readwrite("cross_length", &Cutter::crossLength)
        .def_readonly("start", &Cutter::start)
        .def_readonly("radius", &Cutter::radius);
    py::class_<StockModel>(m, "StockModel")
        .def(py::init<double, double, double, double, py::array_t<float, py::array::c_style | py::array::forcecast>,
                      py::array_t<uint32_t, py::array::c_style | py::array::forcecast>>())
        .def("sweep", &StockModel::sweep)
        .def("meets_excess", &StockModel::meetsExcessBatch)
        .def("material", &StockModel::material)
        .def("material_along", &StockModel::materialAlong)
        .def("removed", [](const StockModel& s, int k) { return s.removed.at(k); })
        .def("part", [](const StockModel& s, int k) { return s.part.at(k); })
        .def("copy", [](const StockModel& s) { return StockModel(s); });
    m.def("dexel_mesh", &dexelMesh);
    py::class_<FixtureField>(m, "FixtureField")
        .def(py::init<py::array_t<double, py::array::c_style | py::array::forcecast>, double, double, double, double, double>())
        .def_readonly("min_x", &FixtureField::minX)
        .def_readonly("min_y", &FixtureField::minY)
        .def_readonly("cell", &FixtureField::cell)
        .def_readonly("nx", &FixtureField::nx)
        .def_readonly("ny", &FixtureField::ny)
        .def("empty", &FixtureField::empty)
        .def("top", &FixtureField::topArray)
        .def("dilated", [](FixtureField& f, double r) {
            const auto& d = f.dilated(r);
            py::array_t<float> out({(py::ssize_t)f.ny, (py::ssize_t)f.nx});
            std::copy(d.begin(), d.end(), out.mutable_data());
            return out;
        })
        .def("intrusions", &FixtureField::intrusions);
    py::class_<TriangleTree>(m, "TriangleTree")
        .def(py::init<py::array_t<double, py::array::c_style | py::array::forcecast>>())
        .def_property_readonly("triangle_count", &TriangleTree::triangleCount)
        .def_property_readonly("bounds", &TriangleTree::boundsPy)
        .def("intersect", &TriangleTree::intersect)
        .def("raycast", &TriangleTree::raycast)
        .def("contains", [](const TriangleTree& t, double x, double y, double z) { return t.contains(V3{x, y, z}); })
        .def("distance", [](const TriangleTree& t, double x, double y, double z, double limit) { return t.distance(V3{x, y, z}, limit); })
        .def("touches", &TriangleTree::touches);
    m.def("tri_tri", [](py::array_t<double> a, py::array_t<double> b, double tol) -> py::object {
        auto A = a.unchecked<2>(); auto B = b.unchecked<2>();
        V3 p, q;
        if (!triTri({A(0,0),A(0,1),A(0,2)}, {A(1,0),A(1,1),A(1,2)}, {A(2,0),A(2,1),A(2,2)},
                    {B(0,0),B(0,1),B(0,2)}, {B(1,0),B(1,1),B(1,2)}, {B(2,0),B(2,1),B(2,2)}, tol, p, q)) return py::none();
        return py::make_tuple(py::make_tuple(p.x, p.y, p.z), py::make_tuple(q.x, q.y, q.z));
    });
    py::class_<Heightmap>(m, "Heightmap")
        .def(py::init<double, double, double, double, double, double, int>())
        .def_readonly("origin_x", &Heightmap::originX)
        .def_readonly("origin_y", &Heightmap::originY)
        .def_readonly("cell", &Heightmap::cell)
        .def_readonly("cols", &Heightmap::cols)
        .def_readonly("rows", &Heightmap::rows)
        .def_readonly("top", &Heightmap::top)
        .def_readonly("bottom", &Heightmap::bottom)
        .def_readonly("heights", &Heightmap::heights)
        .def("cut", &Heightmap::cut)
        .def("cut_path", &Heightmap::cutPath)
        .def("mark_all_dirty", &Heightmap::markAllDirty)
        .def("take_dirty", &Heightmap::takeDirty)
        .def("removed_volume", &Heightmap::removedVolume)
        .def("copy", [](const Heightmap& h) {
            Heightmap c = h;  // py::array shares its buffer: give the copy its own
            c.heights = py::array_t<float>({(py::ssize_t)h.rows, (py::ssize_t)h.cols});
            std::copy(h.heights.data(), h.heights.data() + (size_t)h.rows * h.cols, c.heights.mutable_data());
            return c;
        });
}
