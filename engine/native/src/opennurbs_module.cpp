// coastline_engine._opennurbs: writes a B-rep (from OpenCASCADE, described by clean_3dm.py) as a
// joined Rhino polysurface in a .3dm file, with openNURBS (McNeel's Rhino file toolkit).
//
// Curves and surfaces arrive as NURBS in openNURBS's own knot convention (no superfluous end
// knots) with homogeneous control points (x·w, y·w, [z·w,] w).
#include "opennurbs.h"
#include <pybind11/pybind11.h>
#include <pybind11/stl.h>
#include <string>
#include <tuple>
#include <vector>

namespace py = pybind11;

using Knots = std::vector<double>;
using CVs = std::vector<double>;
// dim, degree, cv_count, knots, cvs (homogeneous, dim + 1 per cv)
using Curve = std::tuple<int, int, int, Knots, CVs>;
// degree_u, degree_v, cv_count_u, cv_count_v, knots_u, knots_v, cvs (4 per cv, u-major)
using Surface = std::tuple<int, int, int, int, Knots, Knots, CVs>;
using Vertex = std::tuple<double, double, double, double>;           // x, y, z, tolerance
using Edge = std::tuple<int, int, int, double>;                       // v0, v1, curve3d, tolerance
using Trim = std::tuple<int, bool, int>;                              // edge, reversed vs edge, curve2d
using Loop = std::tuple<bool, std::vector<Trim>>;                     // outer?, trims
using Face = std::tuple<int, bool, std::vector<Loop>>;                // surface, reversed, loops

static ON_NurbsCurve* make_curve(const Curve& c) {
    auto [dim, degree, count, knots, cvs] = c;
    auto* n = new ON_NurbsCurve(dim, true, degree + 1, count);
    for (int i = 0; i < (int)knots.size(); i++) n->SetKnot(i, knots[i]);
    for (int i = 0; i < count; i++) {
        double* cv = n->CV(i);
        for (int k = 0; k <= dim; k++) cv[k] = cvs[i * (dim + 1) + k];
    }
    return n;
}

static ON_NurbsSurface* make_surface(const Surface& s) {
    auto [du, dv, cu, cv, ku, kv, cvs] = s;
    auto* n = new ON_NurbsSurface(3, true, du + 1, dv + 1, cu, cv);
    for (int i = 0; i < (int)ku.size(); i++) n->SetKnot(0, i, ku[i]);
    for (int i = 0; i < (int)kv.size(); i++) n->SetKnot(1, i, kv[i]);
    for (int i = 0; i < cu; i++)
        for (int j = 0; j < cv; j++) {
            double* p = n->CV(i, j);
            for (int k = 0; k < 4; k++) p[k] = cvs[(i * cv + j) * 4 + k];
        }
    return n;
}

/// Writes the model through a file we open: openNURBS then doesn't know the path, so it can't store
/// it in the file (ONX_Model::Write(filename) records the full path, with the user's folders).
static bool write_anonymous(ONX_Model& model, const std::string& path) {
    FILE* fp = ON::OpenFile(path.c_str(), "wb");
    if (!fp) return false;
    bool ok;
    {
        ON_BinaryFile archive(ON::archive_mode::write3dm, fp);
        ok = model.Write(archive, 7);
    }
    ON::CloseFile(fp);
    return ok;
}

/// Builds the brep, checks it and writes the model. Returns (written, valid, openNURBS's log).
static std::tuple<bool, bool, std::string> write_brep(
    const std::string& path, const std::string& name, const std::string& layer_name,
    const std::vector<Surface>& surfaces, const std::vector<Curve>& curves3, const std::vector<Curve>& curves2,
    const std::vector<Vertex>& vertices, const std::vector<Edge>& edges, const std::vector<Face>& faces) {
    auto* brep = new ON_Brep();
    for (const auto& s : surfaces) brep->AddSurface(make_surface(s));
    for (const auto& c : curves3) brep->AddEdgeCurve(make_curve(c));
    for (const auto& c : curves2) brep->AddTrimCurve(make_curve(c));
    for (const auto& [x, y, z, tol] : vertices) brep->NewVertex(ON_3dPoint(x, y, z), tol);
    for (const auto& [v0, v1, c3, tol] : edges) brep->NewEdge(brep->m_V[v0], brep->m_V[v1], c3, nullptr, tol);
    for (const auto& [si, rev, loops] : faces) {
        ON_BrepFace& face = brep->NewFace(si);
        face.m_bRev = rev;
        for (const auto& [outer, trims] : loops) {
            ON_BrepLoop& loop = brep->NewLoop(outer ? ON_BrepLoop::outer : ON_BrepLoop::inner, face);
            for (const auto& [ei, rev3d, c2] : trims) {
                ON_BrepTrim& t = brep->NewTrim(brep->m_E[ei], rev3d, loop, c2);
                t.m_tolerance[0] = t.m_tolerance[1] = brep->m_E[ei].m_tolerance;
            }
        }
    }
    brep->Compact();  // drops vertices nothing uses (a closed edge's second one)
    brep->SetTrimTypeFlags();
    brep->SetTrimIsoFlags();
    brep->SetTolerancesBoxesAndFlags(true, true, true, true, true, true, true, true);
    ON_wString log_text;
    ON_TextLog log(log_text);
    bool valid = brep->IsValid(&log);

    ONX_Model model;
    model.m_settings.m_ModelUnitsAndTolerances.m_unit_system = ON_UnitSystem(ON::LengthUnitSystem::Millimeters);
    model.m_settings.m_ModelUnitsAndTolerances.m_absolute_tolerance = 0.001;
    model.m_properties.m_Application.m_application_name = L"Coastline";
    int layer = model.AddLayer(ON_wString(layer_name.c_str()), ON_Color::UnsetColor);
    ON_3dmObjectAttributes* attrs = new ON_3dmObjectAttributes();
    attrs->m_layer_index = layer;
    attrs->SetName(ON_wString(name.c_str()), true);
    model.AddManagedModelGeometryComponent(brep, attrs);
    bool written = write_anonymous(model, path);
    return {written, valid, std::string(ON_String(log_text).Array() ? ON_String(log_text).Array() : "")};
}

/// A triangle mesh (a sharp snapshot) as a Rhino mesh object, written without the file's path.
static bool write_mesh(const std::string& path, const std::string& name, const std::string& layer_name,
                       const std::vector<float>& vertices, const std::vector<int>& triangles) {
    const int nv = (int)vertices.size() / 3, nt = (int)triangles.size() / 3;
    auto* mesh = new ON_Mesh(nt, nv, false, false);
    for (int i = 0; i < nv; i++) mesh->SetVertex(i, ON_3fPoint(vertices[3 * i], vertices[3 * i + 1], vertices[3 * i + 2]));
    for (int i = 0; i < nt; i++) mesh->SetTriangle(i, triangles[3 * i], triangles[3 * i + 1], triangles[3 * i + 2]);
    mesh->ComputeVertexNormals();
    mesh->Compact();
    ONX_Model model;
    model.m_settings.m_ModelUnitsAndTolerances.m_unit_system = ON_UnitSystem(ON::LengthUnitSystem::Millimeters);
    model.m_properties.m_Application.m_application_name = L"Coastline";
    int layer = model.AddLayer(ON_wString(layer_name.c_str()), ON_Color::UnsetColor);
    ON_3dmObjectAttributes* attrs = new ON_3dmObjectAttributes();
    attrs->m_layer_index = layer;
    attrs->SetName(ON_wString(name.c_str()), true);
    model.AddManagedModelGeometryComponent(mesh, attrs);
    return write_anonymous(model, path);
}

static bool ping(const std::string& path) {
    ONX_Model model;
    model.m_settings.m_ModelUnitsAndTolerances.m_unit_system = ON_UnitSystem(ON::LengthUnitSystem::Millimeters);
    return write_anonymous(model, path);
}

PYBIND11_MODULE(_opennurbs, m) {
    ON::Begin();
    m.doc() = "openNURBS: write clean B-reps as Rhino .3dm (K12 export)";
    m.def("ping", &ping);
    m.def("write_mesh", &write_mesh, py::arg("path"), py::arg("name"), py::arg("layer"), py::arg("vertices"), py::arg("triangles"));
    m.def("write_brep", &write_brep, py::arg("path"), py::arg("name"), py::arg("layer"), py::arg("surfaces"),
          py::arg("curves3"), py::arg("curves2"), py::arg("vertices"), py::arg("edges"), py::arg("faces"));
}
