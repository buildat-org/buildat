// buildat: builtin/luanti's sky visibility cube, shared by the shaders in
// this directory.
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// How much of the sky the camera can see, per direction, and the lookup that
// reads it. The client raymarches a cube of directions through the voxel
// data it already holds and uploads the result; see skyvis.lua in
// extensions/luanti_client and client_lua/module.lua in
// builtin/voxel_shading, which fill it, and [CAVE_SKY] in
// doc/plan/rendering_plan.md for what reads it.
//
// Included rather than copied because two shaders in this directory want it:
// PBRVoxel.glsl dims what a surface reflects, and SkyDome.glsl dims the
// sky itself. **builtin/voxel_shading has its own copy of the same block**,
// for the nine games that draw with its shaders rather than these; that one
// is not shared, because a change there is checked against
// apps/sample_lighting_scene's images and this file is not on that path.

    // How much of the sky the camera can see, per direction: a cube of
    // SKYVIS_CELLS squared values per face, 1 for full sky and 0 for none,
    // packed four to a vec4 in face, row, column order. The client writes them as one
    // buffer parameter, which Urho hands to a float array uniform; a cube map
    // texture would have to be built and uploaded per update instead.
    //
    // vec4 rather than a float array so the packing is the same whether or not
    // the driver lays uniforms out as std140, where an array of float or vec3
    // pads every element out to four.
    // Cells per cube face, per axis. Six faces of SKYVIS_CELLS squared values,
    // packed four to a vec4, so the array is 6*C*C/4 long -- keep the two in
    // step, and in step with CELLS in the client's module.lua, which fills
    // them.
    const int SKYVIS_CELLS = 6;
    // Its own rather than Urho3D's M_EPSILON, which comes from
    // Constants.glsl: this file is included by a shader that has that and by
    // one that does not, and a shared block should not care which.
    const float SKYVIS_EPSILON = 0.0001;
    uniform vec4 cSkyVis[54];

    float SkyVisCell(int face, int row, int col)
    {
        // "flat" is a reserved word in GLSL, hence the name
        int cell = (face * SKYVIS_CELLS + row) * SKYVIS_CELLS + col;
        return cSkyVis[cell / 4][cell - (cell / 4) * 4];
    }

    // How much sky is visible along dir. The largest component of the
    // direction picks the cube face and the other two, divided by it, are the
    // position on that face in -1..1; the client builds a cell's direction the
    // same way round, so the two agree without either of them following a cube
    // map face convention. Bilinear between cell centers, clamped at the face
    // edges the way a cube map with clamped wrapping would be: neighbouring
    // faces' edge cells look nearly the same way, so the seam does not show.
    float GetSkyVisibility(vec3 dir)
    {
        vec3 a = abs(dir);
        float m, u, v;
        int face;
        if (a.x >= a.y && a.x >= a.z)
        {
            m = a.x;
            face = dir.x >= 0.0 ? 0 : 1;
            u = dir.y;
            v = dir.z;
        }
        else if (a.y >= a.z)
        {
            m = a.y;
            face = dir.y >= 0.0 ? 2 : 3;
            u = dir.x;
            v = dir.z;
        }
        else
        {
            m = a.z;
            face = dir.z >= 0.0 ? 4 : 5;
            u = dir.x;
            v = dir.y;
        }
        m = max(m, SKYVIS_EPSILON);
        // Cell centers sit half a cell in from each edge, so the position in
        // cells is the position across the face times the cell count, less a
        // half
        float half_cells = float(SKYVIS_CELLS) * 0.5;
        float last = float(SKYVIS_CELLS - 1);
        float fu = clamp((u / m + 1.0) * half_cells - 0.5, 0.0, last);
        float fv = clamp((v / m + 1.0) * half_cells - 0.5, 0.0, last);
        int c0 = int(fu);
        int c1 = min(c0 + 1, SKYVIS_CELLS - 1);
        int r0 = int(fv);
        int r1 = min(r0 + 1, SKYVIS_CELLS - 1);
        float tu = fu - float(c0);
        return mix(
            mix(SkyVisCell(face, r0, c0), SkyVisCell(face, r0, c1), tu),
            mix(SkyVisCell(face, r1, c0), SkyVisCell(face, r1, c1), tu),
            fv - float(r0));
    }
