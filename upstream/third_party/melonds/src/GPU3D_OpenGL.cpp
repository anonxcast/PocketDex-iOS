/*
    Copyright 2016-2025 melonDS team

    This file is part of melonDS.

    melonDS is free software: you can redistribute it and/or modify it under
    the terms of the GNU General Public License as published by the Free
    Software Foundation, either version 3 of the License, or (at your option)
    any later version.

    melonDS is distributed in the hope that it will be useful, but WITHOUT ANY
    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
    FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along
    with melonDS. If not, see http://www.gnu.org/licenses/.
*/

#include "GPU3D_OpenGL.h"

#include <algorithm>
#include <cmath>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "NDS.h"
#include "GPU.h"
#include "GPU3D_OpenGL_shaders.h"

namespace melonDS
{

bool GLRenderer::BuildRenderShader(u32 flags, const std::string& vs, const std::string& fs)
{
    char shadername[32];
    snprintf(shadername, sizeof(shadername), "RenderShader%02X", flags);

    int headerlen = strlen(kShaderHeader);

    std::string vsbuf;
    vsbuf += kShaderHeader;
    vsbuf += kRenderVSCommon;
    vsbuf += vs;

    std::string fsbuf;
    fsbuf += kShaderHeader;
    fsbuf += kRenderFSCommon;
    fsbuf += fs;

    GLuint prog;
    bool ret = OpenGL::CompileVertexFragmentProgram(prog,
        vsbuf, fsbuf,
        shadername,
        {{"vPosition", 0}, {"vColor", 1}, {"vTexcoord", 2}, {"vPolygonAttr", 3}},
        {{"oColor", 0}, {"oAttr", 1}});

    if (!ret) return false;

    GLint uni_id = glGetUniformBlockIndex(prog, "uConfig");
    glUniformBlockBinding(prog, uni_id, 0);

    glUseProgram(prog);

    uni_id = glGetUniformLocation(prog, "TexMem");
    glUniform1i(uni_id, 0);
    uni_id = glGetUniformLocation(prog, "TexPalMem");
    glUniform1i(uni_id, 1);

    RenderShader[flags] = prog;

    return true;
}

void GLRenderer::UseRenderShader(u32 flags)
{
    if (CurShaderID == flags) return;
    glUseProgram(RenderShader[flags]);
    CurShaderID = flags;
}

void SetupDefaultTexParams(GLuint tex)
{
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
}

GLRenderer::GLRenderer(GLCompositor&& compositor) noexcept :
    Renderer3D(true),
    CurGLCompositor(std::move(compositor))
{
    // GLRenderer::New() will be used to actually initialize the renderer;
    // The various glDelete* functions silently ignore invalid IDs,
    // so we can just let the destructor clean up a half-initialized renderer.
}

std::unique_ptr<GLRenderer> GLRenderer::New() noexcept
{
    assert(glEnable != nullptr);

    std::optional<GLCompositor> compositor =  GLCompositor::New();
    if (!compositor)
        return nullptr;

    // Will be returned if the initialization succeeds,
    // or cleaned up via RAII if it fails.
    std::unique_ptr<GLRenderer> result = std::unique_ptr<GLRenderer>(new GLRenderer(std::move(*compositor)));
    compositor = std::nullopt;

    glEnable(GL_DEPTH_TEST);
    glEnable(GL_STENCIL_TEST);

#ifdef MELONDS_GLES
    glDepthRangef(0, 1);
    glClearDepthf(1.0f);
#else
    glDepthRange(0, 1);
    glClearDepth(1.0);
#endif

    if (!OpenGL::CompileVertexFragmentProgram(result->ClearShaderPlain,
            kClearVS, kClearFS,
            "ClearShader",
            {{"vPosition", 0}},
            {{"oColor", 0}, {"oAttr", 1}}))
        return nullptr;

    result->ClearUniformLoc[0] = glGetUniformLocation(result->ClearShaderPlain, "uColor");
    result->ClearUniformLoc[1] = glGetUniformLocation(result->ClearShaderPlain, "uDepth");
    result->ClearUniformLoc[2] = glGetUniformLocation(result->ClearShaderPlain, "uOpaquePolyID");
    result->ClearUniformLoc[3] = glGetUniformLocation(result->ClearShaderPlain, "uFogFlag");

    memset(result->RenderShader, 0, sizeof(RenderShader));

    if (!result->BuildRenderShader(0, kRenderVS_Z, kRenderFS_ZO))
        return nullptr;

    if (!result->BuildRenderShader(RenderFlag_WBuffer, kRenderVS_W, kRenderFS_WO))
        return nullptr;

    if (!result->BuildRenderShader(RenderFlag_Edge, kRenderVS_Z, kRenderFS_ZE))
        return nullptr;

    if (!result->BuildRenderShader(RenderFlag_Edge | RenderFlag_WBuffer, kRenderVS_W, kRenderFS_WE))
        return nullptr;

    if (!result->BuildRenderShader(RenderFlag_Trans, kRenderVS_Z, kRenderFS_ZT))
        return nullptr;

    if (!result->BuildRenderShader(RenderFlag_Trans | RenderFlag_WBuffer, kRenderVS_W, kRenderFS_WT))
        return nullptr;

    if (!result->BuildRenderShader(RenderFlag_ShadowMask, kRenderVS_Z, kRenderFS_ZSM))
        return nullptr;

    if (!result->BuildRenderShader(RenderFlag_ShadowMask | RenderFlag_WBuffer, kRenderVS_W, kRenderFS_WSM))
        return nullptr;

    if (!OpenGL::CompileVertexFragmentProgram(result->FinalPassEdgeShader,
            kFinalPassVS, kFinalPassEdgeFS,
            "FinalPassEdgeShader",
            {{"vPosition", 0}},
            {{"oColor", 0}}))
        return nullptr;
    if (!OpenGL::CompileVertexFragmentProgram(result->FinalPassFogShader,
            kFinalPassVS, kFinalPassFogFS,
            "FinalPassFogShader",
            {{"vPosition", 0}},
            {{"oColor", 0}}))
        return nullptr;

    GLuint uni_id = glGetUniformBlockIndex(result->FinalPassEdgeShader, "uConfig");
    glUniformBlockBinding(result->FinalPassEdgeShader, uni_id, 0);

    glUseProgram(result->FinalPassEdgeShader);
    uni_id = glGetUniformLocation(result->FinalPassEdgeShader, "DepthBuffer");
    glUniform1i(uni_id, 0);
    uni_id = glGetUniformLocation(result->FinalPassEdgeShader, "AttrBuffer");
    glUniform1i(uni_id, 1);

    uni_id = glGetUniformBlockIndex(result->FinalPassFogShader, "uConfig");
    glUniformBlockBinding(result->FinalPassFogShader, uni_id, 0);

    glUseProgram(result->FinalPassFogShader);
    uni_id = glGetUniformLocation(result->FinalPassFogShader, "DepthBuffer");
    glUniform1i(uni_id, 0);
    uni_id = glGetUniformLocation(result->FinalPassFogShader, "AttrBuffer");
    glUniform1i(uni_id, 1);


    memset(&result->ShaderConfig, 0, sizeof(ShaderConfig));

    glGenBuffers(1, &result->ShaderConfigUBO);
    glBindBuffer(GL_UNIFORM_BUFFER, result->ShaderConfigUBO);
    static_assert((sizeof(ShaderConfig) & 15) == 0);
    glBufferData(GL_UNIFORM_BUFFER, sizeof(ShaderConfig), &result->ShaderConfig, GL_STATIC_DRAW);
    glBindBufferBase(GL_UNIFORM_BUFFER, 0, result->ShaderConfigUBO);


    float clearvtx[6*2] =
    {
        -1.0, -1.0,
        1.0, 1.0,
        -1.0, 1.0,

        -1.0, -1.0,
        1.0, -1.0,
        1.0, 1.0
    };

    glGenBuffers(1, &result->ClearVertexBufferID);
    glBindBuffer(GL_ARRAY_BUFFER, result->ClearVertexBufferID);
    glBufferData(GL_ARRAY_BUFFER, sizeof(clearvtx), clearvtx, GL_STATIC_DRAW);

    glGenVertexArrays(1, &result->ClearVertexArrayID);
    glBindVertexArray(result->ClearVertexArrayID);
    glEnableVertexAttribArray(0); // position
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, (void*)(0));


    glGenBuffers(1, &result->VertexBufferID);
    glBindBuffer(GL_ARRAY_BUFFER, result->VertexBufferID);
    glBufferData(GL_ARRAY_BUFFER, sizeof(VertexBuffer), nullptr, GL_DYNAMIC_DRAW);

    glGenVertexArrays(1, &result->VertexArrayID);
    glBindVertexArray(result->VertexArrayID);
    glEnableVertexAttribArray(0); // position
    glVertexAttribIPointer(0, 4, GL_UNSIGNED_SHORT, 7*4, (void*)(0));
    glEnableVertexAttribArray(1); // color
    glVertexAttribIPointer(1, 4, GL_UNSIGNED_BYTE, 7*4, (void*)(2*4));
    glEnableVertexAttribArray(2); // texcoords
    glVertexAttribIPointer(2, 2, GL_SHORT, 7*4, (void*)(3*4));
    glEnableVertexAttribArray(3); // attrib
    glVertexAttribIPointer(3, 3, GL_UNSIGNED_INT, 7*4, (void*)(4*4));

    glGenBuffers(1, &result->IndexBufferID);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, result->IndexBufferID);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(IndexBuffer), nullptr, GL_DYNAMIC_DRAW);

    glGenFramebuffers(1, &result->MainFramebuffer);
    glGenFramebuffers(1, &result->DownscaleFramebuffer);
    glGenFramebuffers(1, &result->FinalPassFramebuffer);

    // color buffers
    glGenTextures(2, result->ColorBufferTex);
    SetupDefaultTexParams(result->ColorBufferTex[0]);
    SetupDefaultTexParams(result->ColorBufferTex[1]);

    // depth/stencil buffer
    glGenTextures(1, &result->DepthBufferTex);
    SetupDefaultTexParams(result->DepthBufferTex);

    // attribute buffer
    // R: opaque polyID (for edgemarking)
    // G: edge flag
    // B: fog flag
    glGenTextures(1, &result->AttrBufferTex);
    SetupDefaultTexParams(result->AttrBufferTex);

    // downscale framebuffer for display capture (always 256x192)
    glGenTextures(1, &result->DownScaleBufferTex);
    SetupDefaultTexParams(result->DownScaleBufferTex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 256, 192, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);

    glEnable(GL_BLEND);
    glBlendEquationSeparate(GL_FUNC_ADD, GL_MAX);

    glGenBuffers(1, &result->PixelbufferID);

    glActiveTexture(GL_TEXTURE0);
    glGenTextures(1, &result->TexMemID);
    glBindTexture(GL_TEXTURE_2D, result->TexMemID);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8UI, 1024, 512, 0, GL_RED_INTEGER, GL_UNSIGNED_BYTE, NULL);

    glActiveTexture(GL_TEXTURE1);
    glGenTextures(1, &result->TexPalMemID);
    glBindTexture(GL_TEXTURE_2D, result->TexPalMemID);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    // PokeDaisy: raw BGR555 halfwords, decoded in the shader (PalFetch): OpenGL ES has no 1_5_5_5_REV upload.
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R16UI, 1024, 48, 0, GL_RED_INTEGER, GL_UNSIGNED_SHORT, NULL);

    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    return result;
}

GLRenderer::~GLRenderer()
{
    assert(glDeleteTextures != nullptr);

    glDeleteTextures(1, &TexMemID);
    glDeleteTextures(1, &TexPalMemID);

    glDeleteFramebuffers(1, &MainFramebuffer);
    glDeleteFramebuffers(1, &DownscaleFramebuffer);
    glDeleteFramebuffers(1, &FinalPassFramebuffer);
    glDeleteBuffers(1, &PixelbufferID);
    glDeleteBuffers(1, &IndexBufferID);
    glDeleteTextures(2, ColorBufferTex);
    glDeleteTextures(1, &DepthBufferTex);
    glDeleteTextures(1, &AttrBufferTex);
    glDeleteTextures(1, &DownScaleBufferTex);

    glDeleteVertexArrays(1, &VertexArrayID);
    glDeleteBuffers(1, &VertexBufferID);
    glDeleteVertexArrays(1, &ClearVertexArrayID);
    glDeleteBuffers(1, &ClearVertexBufferID);

    glDeleteBuffers(1, &ShaderConfigUBO);

    for (int i = 0; i < 16; i++)
    {
        if (!RenderShader[i]) continue;
        glDeleteProgram(RenderShader[i]);
    }
}

void GLRenderer::Reset(GPU& gpu)
{
    // This is where the compositor's Reset() method would be called,
    // except there's no such method right now.
}

void GLRenderer::SetBetterPolygons(bool betterpolygons) noexcept
{
    SetRenderSettings(betterpolygons, ScaleFactor);
}

void GLRenderer::SetScaleFactor(int scale) noexcept
{
    SetRenderSettings(BetterPolygons, scale);
}


void GLRenderer::SetRenderSettings(bool betterpolygons, int scale) noexcept
{
    if (betterpolygons == BetterPolygons && scale == ScaleFactor)
        return;

    CurGLCompositor.SetScaleFactor(scale);
    ScaleFactor = scale;
    BetterPolygons = betterpolygons;

    ScreenW = 256 * scale;
    ScreenH = 192 * scale;
    CurScale = scale;
    EnsureTarget(ScreenW, ScreenH);

    glBindFramebuffer(GL_FRAMEBUFFER, DownscaleFramebuffer);
    glFramebufferTexture(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, DownScaleBufferTex, 0);

    glBindBuffer(GL_PIXEL_PACK_BUFFER, PixelbufferID);
    glBufferData(GL_PIXEL_PACK_BUFFER, 256*192*4, NULL, GL_DYNAMIC_READ);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);

    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    //glLineWidth(scale);
    //glLineWidth(1.5);
}


// PokeDaisy: the depth / attribute textures and this frame's colour texture at least w x h (EXPAND's views come and go
// with the camera): grown to fit with room to spare, shrunk only when far too big. The other colour texture keeps its
// size and picture - the frame shown draws from it.
static bool NeedsResize(int haveW, int haveH, int w, int h)
{
    return w > haveW || h > haveH || (s64)w * h * 4 < (s64)haveW * haveH;
}

static void GrowSize(int& w, int& h)
{
    // A camera easing out grows the view a little each frame: an eighth more each way, in steps of 64.
    w = ((w + w / 8) + 63) & ~63;
    h = ((h + h / 8) + 63) & ~63;
}

void GLRenderer::EnsureTarget(int w, int h) noexcept
{
    if (NeedsResize(TargetW, TargetH, w, h))
    {
        int tw = w, th = h;
        if (w > 256 * ScaleFactor || h > 192 * ScaleFactor) GrowSize(tw, th);
        TargetW = tw;
        TargetH = th;
        glBindTexture(GL_TEXTURE_2D, DepthBufferTex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH24_STENCIL8, TargetW, TargetH, 0, GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, NULL);
        glBindTexture(GL_TEXTURE_2D, AttrBufferTex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, TargetW, TargetH, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);

        GLenum fbassign[2] = {GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1};

        glBindFramebuffer(GL_FRAMEBUFFER, MainFramebuffer);
        glFramebufferTexture(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, DepthBufferTex, 0);
        glFramebufferTexture(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, AttrBufferTex, 0);
        glDrawBuffers(2, fbassign);

        glBindFramebuffer(GL_FRAMEBUFFER, FinalPassFramebuffer);
        glDrawBuffers(1, fbassign);
    }
    for (int i = 0; i < 2; i++)
    {
        // this frame's to fit; the other only before it has any storage (sampled before its first frame is drawn)
        int c = CurColor ^ i;
        if (i == 0 ? !NeedsResize(ColorW[c], ColorH[c], w, h) : ColorW[c] > 0)
            continue;
        ColorW[c] = TargetW;
        ColorH[c] = TargetH;
        glBindTexture(GL_TEXTURE_2D, ColorBufferTex[c]);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, TargetW, TargetH, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    }
    AttachColor();
}

// PokeDaisy: the colour texture this frame's 3D is drawn into, on both framebuffers.
void GLRenderer::AttachColor() noexcept
{
    glBindFramebuffer(GL_FRAMEBUFFER, MainFramebuffer);
    glFramebufferTexture(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, ColorBufferTex[CurColor], 0);
    glBindFramebuffer(GL_FRAMEBUFFER, FinalPassFramebuffer);
    glFramebufferTexture(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, ColorBufferTex[CurColor], 0);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
}

void GLRenderer::SetupPolygon(GLRenderer::RendererPolygon* rp, Polygon* polygon) const
{
    rp->PolyData = polygon;

    // render key: depending on what we're drawing
    // opaque polygons:
    // - depthfunc
    // -- alpha=0
    // regular translucent polygons:
    // - depthfunc
    // -- depthwrite
    // --- polyID
    // ---- need opaque
    // shadow mask polygons:
    // - depthfunc?????
    // shadow polygons:
    // - depthfunc
    // -- depthwrite
    // --- polyID

    rp->RenderKey = (polygon->Attr >> 14) & 0x1; // bit14 - depth func
    if (!polygon->IsShadowMask)
    {
        if (polygon->Translucent)
        {
            if (polygon->IsShadow) rp->RenderKey |= 0x20000;
            else                   rp->RenderKey |= 0x10000;
            rp->RenderKey |= (polygon->Attr >> 10) & 0x2; // bit11 - depth write
            rp->RenderKey |= (polygon->Attr >> 13) & 0x4; // bit15 - fog
            rp->RenderKey |= (polygon->Attr & 0x3F000000) >> 16; // polygon ID
            if ((polygon->Attr & 0x001F0000) == 0x001F0000) // need opaque
                rp->RenderKey |= 0x4000;
        }
        else
        {
            if ((polygon->Attr & 0x001F0000) == 0)
                rp->RenderKey |= 0x2;
            rp->RenderKey |= (polygon->Attr & 0x3F000000) >> 16; // polygon ID
        }
    }
    else
    {
        rp->RenderKey |= 0x30000;
    }
}

u32* GLRenderer::SetupVertex(const Polygon* poly, int vid, const Vertex* vtx, u32 vtxattr, u32* vptr) const
{
    u32 z = poly->FinalZ[vid];
    u32 w = poly->FinalW[vid];

    u32 alpha = (poly->Attr >> 16) & 0x1F;

    // Z should always fit within 16 bits, so it's okay to do this
    u32 zshift = 0;
    while (z > 0xFFFF) { z >>= 1; zshift++; }

    u32 x, y;
    if (CurScale > 1)
    {
        x = (vtx->HiresPosition[0] * CurScale) >> 4;
        y = (vtx->HiresPosition[1] * CurScale) >> 4;
    }
    else
    {
        x = vtx->FinalPosition[0];
        y = vtx->FinalPosition[1];
    }

    // correct nearly-vertical edges that would look vertical on the DS
    /*{
        int vtopid = vid - 1;
        if (vtopid < 0) vtopid = poly->NumVertices-1;
        Vertex* vtop = poly->Vertices[vtopid];
        if (vtop->FinalPosition[1] >= vtx->FinalPosition[1])
        {
            vtopid = vid + 1;
            if (vtopid >= poly->NumVertices) vtopid = 0;
            vtop = poly->Vertices[vtopid];
        }
        if ((vtop->FinalPosition[1] < vtx->FinalPosition[1]) &&
            (vtx->FinalPosition[0] == vtop->FinalPosition[0]-1))
        {
            if (ScaleFactor > 1)
                x = (vtop->HiresPosition[0] * ScaleFactor) >> 4;
            else
                x = vtop->FinalPosition[0];
        }
    }*/

    *vptr++ = x | (y << 16);
    *vptr++ = z | (w << 16);

    *vptr++ =  (vtx->FinalColor[0] >> 1) |
              ((vtx->FinalColor[1] >> 1) << 8) |
              ((vtx->FinalColor[2] >> 1) << 16) |
              (alpha << 24);

    *vptr++ = (u16)vtx->TexCoords[0] | ((u16)vtx->TexCoords[1] << 16);

    *vptr++ = vtxattr | (zshift << 16);
    *vptr++ = poly->TexParam;
    *vptr++ = poly->TexPalette;

    return vptr;
}

// PokeDaisy: a convex polygon's n vertices (7 words each, x | y << 16 in the first) moved so that every edge lies [d]
// texels further out, square to itself.
static void GrowPolygon(u32* v, u32 n, float d)
{
    float x[11], y[11], cx = 0, cy = 0;
    for (u32 i = 0; i < n; i++)
    {
        x[i] = (float)(v[i * 7] & 0xFFFF);
        y[i] = (float)(v[i * 7] >> 16);
        cx += x[i];
        cy += y[i];
    }
    cx /= n;
    cy /= n;
    // each edge's outward normal (from vertex i to i + 1), zero for a degenerate one
    float nx[11], ny[11];
    for (u32 i = 0; i < n; i++)
    {
        u32 j = (i + 1) % n;
        float ex = x[j] - x[i], ey = y[j] - y[i];
        float len = std::sqrt(ex * ex + ey * ey);
        if (len < 0.5f) { nx[i] = ny[i] = 0; continue; }
        nx[i] = ey / len;
        ny[i] = -ex / len;
        if (nx[i] * ((x[i] + x[j]) * 0.5f - cx) + ny[i] * ((y[i] + y[j]) * 0.5f - cy) < 0) { nx[i] = -nx[i]; ny[i] = -ny[i]; }
    }
    for (u32 i = 0; i < n; i++)
    {
        // the corner between edge i - 1 and edge i, mitred (at most twice d out, for a sharp corner)
        u32 p = (i + n - 1) % n;
        float mx = nx[p] + nx[i], my = ny[p] + ny[i];
        float k = 1.0f + nx[p] * nx[i] + ny[p] * ny[i];
        if (k < 0.5f) k = 0.5f;
        float ox = d * mx / k, oy = d * my / k;
        s32 gx = (s32)std::lround(x[i] + ox), gy = (s32)std::lround(y[i] + oy);
        v[i * 7] = (u32)std::clamp(gx, 0, 0xFFFF) | ((u32)std::clamp(gy, 0, 0xFFFF) << 16);
    }
}

void GLRenderer::BuildPolygons(GLRenderer::RendererPolygon* polygons, int npolys)
{
    u32* vptr = &VertexBuffer[0];
    u32 vidx = 0;

    u32 iidx = 0;
    u32 eidx = EdgeIndicesOffset;

    for (int i = 0; i < npolys; i++)
    {
        RendererPolygon* rp = &polygons[i];
        Polygon* poly = rp->PolyData;

        // PokeDaisy: no room for another polygon's vertices (one more for 'better' splitting's centre): the rest
        // are left out.
        if (vidx + poly->NumVertices + 1 > MaxVertices)
        {
            NumFinalPolys = i;
            if (NumOpaqueFinalPolys >= i) NumOpaqueFinalPolys = -1;
            break;
        }

        rp->IndicesOffset = iidx;
        rp->NumIndices = 0;

        u32 vidx_first = vidx;

        u32 polyattr = poly->Attr;

        u32 alpha = (polyattr >> 16) & 0x1F;

        u32 vtxattr = polyattr & 0x1F00C8F0;
        if (poly->FacingView) vtxattr |= (1<<8);
        if (poly->WBuffer)    vtxattr |= (1<<9);

        // assemble vertices
        if (poly->Type == 1) // line
        {
            rp->PrimType = GL_LINES;

            u32 lastx, lasty;
            int nout = 0;
            for (u32 j = 0; j < poly->NumVertices; j++)
            {
                Vertex* vtx = poly->Vertices[j];

                if (j > 0)
                {
                    if (lastx == vtx->FinalPosition[0] &&
                        lasty == vtx->FinalPosition[1]) continue;
                }

                lastx = vtx->FinalPosition[0];
                lasty = vtx->FinalPosition[1];

                vptr = SetupVertex(poly, j, vtx, vtxattr, vptr);

                IndexBuffer[iidx++] = vidx;
                rp->NumIndices++;

                vidx++;
                nout++;
                if (nout >= 2) break;
            }
        }
        else if (poly->NumVertices == 3) // regular triangle
        {
            rp->PrimType = GL_TRIANGLES;

            for (int j = 0; j < 3; j++)
            {
                Vertex* vtx = poly->Vertices[j];

                vptr = SetupVertex(poly, j, vtx, vtxattr, vptr);
                vidx++;
            }

            // build a triangle
            IndexBuffer[iidx++] = vidx_first;
            IndexBuffer[iidx++] = vidx - 2;
            IndexBuffer[iidx++] = vidx - 1;
            rp->NumIndices += 3;
        }
        else // quad, pentagon, etc
        {
            rp->PrimType = GL_TRIANGLES;

            if (!BetterPolygons)
            {
                // regular triangle-splitting

                for (u32 j = 0; j < poly->NumVertices; j++)
                {
                    Vertex* vtx = poly->Vertices[j];

                    vptr = SetupVertex(poly, j, vtx, vtxattr, vptr);

                    if (j >= 2)
                    {
                        // build a triangle
                        IndexBuffer[iidx++] = vidx_first;
                        IndexBuffer[iidx++] = vidx - 1;
                        IndexBuffer[iidx++] = vidx;
                        rp->NumIndices += 3;
                    }

                    vidx++;
                }
            }
            else
            {
                // attempt at 'better' splitting
                // this doesn't get rid of the error while splitting a bigger polygon into triangles
                // but we can attempt to reduce it

                u32 cX = 0, cY = 0;
                float cZ = 0;
                float cW = 0;

                float cR = 0, cG = 0, cB = 0;
                float cS = 0, cT = 0;

                for (u32 j = 0; j < poly->NumVertices; j++)
                {
                    Vertex* vtx = poly->Vertices[j];

                    cX += vtx->HiresPosition[0];
                    cY += vtx->HiresPosition[1];

                    float fw = (float)poly->FinalW[j] * poly->NumVertices;
                    cW += 1.0f / fw;

                    if (poly->WBuffer) cZ += poly->FinalZ[j] / fw;
                    else               cZ += poly->FinalZ[j];

                    cR += (vtx->FinalColor[0] >> 1) / fw;
                    cG += (vtx->FinalColor[1] >> 1) / fw;
                    cB += (vtx->FinalColor[2] >> 1) / fw;

                    cS += vtx->TexCoords[0] / fw;
                    cT += vtx->TexCoords[1] / fw;
                }

                cX /= poly->NumVertices;
                cY /= poly->NumVertices;

                cW = 1.0f / cW;

                if (poly->WBuffer) cZ *= cW;
                else               cZ /= poly->NumVertices;

                cR *= cW;
                cG *= cW;
                cB *= cW;

                cS *= cW;
                cT *= cW;

                cX = (cX * CurScale) >> 4;
                cY = (cY * CurScale) >> 4;

                u32 w = (u32)cW;

                u32 z = (u32)cZ;
                u32 zshift = 0;
                while (z > 0xFFFF) { z >>= 1; zshift++; }

                // build center vertex
                *vptr++ = cX | (cY << 16);
                *vptr++ = z | (w << 16);

                *vptr++ =  (u32)cR |
                          ((u32)cG << 8) |
                          ((u32)cB << 16) |
                          (alpha << 24);

                *vptr++ = (u16)cS | ((u16)cT << 16);

                *vptr++ = vtxattr | (zshift << 16);
                *vptr++ = poly->TexParam;
                *vptr++ = poly->TexPalette;

                vidx++;

                // build the final polygon
                for (u32 j = 0; j < poly->NumVertices; j++)
                {
                    Vertex* vtx = poly->Vertices[j];

                    vptr = SetupVertex(poly, j, vtx, vtxattr, vptr);

                    if (j >= 1)
                    {
                        // build a triangle
                        IndexBuffer[iidx++] = vidx_first;
                        IndexBuffer[iidx++] = vidx - 1;
                        IndexBuffer[iidx++] = vidx;
                        rp->NumIndices += 3;
                    }

                    vidx++;
                }

                IndexBuffer[iidx++] = vidx_first;
                IndexBuffer[iidx++] = vidx - 1;
                IndexBuffer[iidx++] = vidx_first + 1;
                rp->NumIndices += 3;
            }
        }

        // PokeDaisy: at 2x and up, where a polygon's corner sits on its neighbour's side (Gen 4's map blocks), the two
        // edges round apart and the clear colour shows through between them, a black line. Opaque polygons grow: each edge
        // moves out by a texel or two, square to itself, the corners mitred (pushing the corners away from the centre
        // left long thin strips as thin). Translucent ones are left alone: they'd blend twice where they overlap.
        if (CurScale > 1 && poly->Type != 1 && !poly->Translucent && !poly->IsShadowMask && vidx - vidx_first >= 3 &&
            (!BetterPolygons || poly->NumVertices == 3))   // (better splitting adds a centre vertex)
            GrowPolygon(&VertexBuffer[vidx_first * 7], vidx - vidx_first, CurScale >= 5 ? 2.0f : 1.0f);

        rp->EdgeIndicesOffset = eidx;
        rp->NumEdgeIndices = 0;

        u32 vidx_cur = vidx_first;
        for (u32 j = 1; j < poly->NumVertices; j++)
        {
            IndexBuffer[eidx++] = vidx_cur;
            IndexBuffer[eidx++] = vidx_cur + 1;
            vidx_cur++;
            rp->NumEdgeIndices += 2;
        }
        IndexBuffer[eidx++] = vidx_cur;
        IndexBuffer[eidx++] = vidx_first;
        rp->NumEdgeIndices += 2;
    }

    NumVertices = vidx;
    NumIndices = iidx;
    NumEdgeIndices = eidx - EdgeIndicesOffset;
}

int GLRenderer::RenderSinglePolygon(int i) const
{
    const RendererPolygon* rp = &PolygonList[i];

    glDrawElements(rp->PrimType, rp->NumIndices, GL_UNSIGNED_SHORT, (void*)(uintptr_t)(rp->IndicesOffset * 2));

    return 1;
}

int GLRenderer::RenderPolygonBatch(int i) const
{
    const RendererPolygon* rp = &PolygonList[i];
    GLuint primtype = rp->PrimType;
    u32 key = rp->RenderKey;
    int numpolys = 0;
    u32 numindices = 0;

    for (int iend = i; iend < NumFinalPolys; iend++)
    {
        const RendererPolygon* cur_rp = &PolygonList[iend];
        if (cur_rp->PrimType != primtype) break;
        if (cur_rp->RenderKey != key) break;

        numpolys++;
        numindices += cur_rp->NumIndices;
    }

    glDrawElements(primtype, numindices, GL_UNSIGNED_SHORT, (void*)(uintptr_t)(rp->IndicesOffset * 2));
    return numpolys;
}

int GLRenderer::RenderPolygonEdgeBatch(int i) const
{
    const RendererPolygon* rp = &PolygonList[i];
    u32 key = rp->RenderKey;
    int numpolys = 0;
    u32 numindices = 0;

    for (int iend = i; iend < NumFinalPolys; iend++)
    {
        const RendererPolygon* cur_rp = &PolygonList[iend];
        if (cur_rp->RenderKey != key) break;

        numpolys++;
        numindices += cur_rp->NumEdgeIndices;
    }

    glDrawElements(GL_LINES, numindices, GL_UNSIGNED_SHORT, (void*)(uintptr_t)(rp->EdgeIndicesOffset * 2));
    return numpolys;
}

void GLRenderer::RenderSceneChunk(const GPU3D& gpu3d, int y, int h)
{
    u32 flags = 0;
    if (PolygonList[0].PolyData->WBuffer) flags |= RenderFlag_WBuffer;

    if (h != 192) glScissor(0, y*CurScale, ScreenW, h*CurScale);

    GLboolean fogenable = (gpu3d.RenderDispCnt & (1<<7)) ? GL_TRUE : GL_FALSE;

    // TODO: proper 'equal' depth test!
    // (has margin of +-0x200 in Z-buffer mode, +-0xFF in W-buffer mode)
    // for now we're using GL_LEQUAL to make it work to some extent

    // pass 1: opaque pixels

    UseRenderShader(flags);
    glLineWidth(1.0);

    glColorMaski(1, GL_TRUE, GL_TRUE, fogenable, GL_FALSE);

    glDepthFunc(GL_LESS);
    glDepthMask(GL_TRUE);

    glBindVertexArray(VertexArrayID);

    for (int i = 0; i < NumFinalPolys; )
    {
        RendererPolygon* rp = &PolygonList[i];

        if (rp->PolyData->IsShadowMask) { i++; continue; }
        if (rp->PolyData->Translucent) { i++; continue; }

        if (rp->PolyData->Attr & (1<<14))
            glDepthFunc(GL_LEQUAL);
        else
            glDepthFunc(GL_LESS);

        u32 polyattr = rp->PolyData->Attr;
        u32 polyid = (polyattr >> 24) & 0x3F;

        glStencilFunc(GL_ALWAYS, polyid, 0xFF);
        glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
        glStencilMask(0xFF);

        i += RenderPolygonBatch(i);
    }

    // if edge marking is enabled, mark all opaque edges
    // TODO BETTER EDGE MARKING!!! THIS SUCKS
    /*if (RenderDispCnt & (1<<5))
    {
        UseRenderShader(flags | RenderFlag_Edge);
        glLineWidth(1.5);

        glColorMaski(0, GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
        glColorMaski(1, GL_FALSE, GL_TRUE, GL_FALSE, GL_FALSE);

        glDepthFunc(GL_ALWAYS);
        glDepthMask(GL_FALSE);

        glStencilFunc(GL_ALWAYS, 0, 0xFF);
        glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP);
        glStencilMask(0);

        for (int i = 0; i < NumFinalPolys; )
        {
            RendererPolygon* rp = &PolygonList[i];

            if (rp->PolyData->IsShadowMask) { i++; continue; }

            i += RenderPolygonEdgeBatch(i);
        }

        glDepthMask(GL_TRUE);
    }*/

    glEnable(GL_BLEND);
    glBlendEquationSeparate(GL_FUNC_ADD, GL_MAX);

    if (gpu3d.RenderDispCnt & (1<<3))
        glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE);
    else
        glBlendFuncSeparate(GL_ONE, GL_ZERO, GL_ONE, GL_ONE);

    glLineWidth(1.0);

    if (NumOpaqueFinalPolys > -1)
    {
        // pass 2: if needed, render translucent pixels that are against background pixels
        // when background alpha is zero, those need to be rendered with blending disabled

        if ((gpu3d.RenderClearAttr1 & 0x001F0000) == 0)
        {
            glDisable(GL_BLEND);

            for (int i = 0; i < NumFinalPolys; )
            {
                RendererPolygon* rp = &PolygonList[i];

                if (rp->PolyData->IsShadowMask)
                {
                    // draw actual shadow mask

                    UseRenderShader(flags | RenderFlag_ShadowMask);

                    glDisable(GL_BLEND);
                    glColorMaski(0, GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
                    glColorMaski(1, GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
                    glDepthMask(GL_FALSE);

                    glDepthFunc(GL_LESS);
                    glStencilFunc(GL_EQUAL, 0xFF, 0xFF);
                    glStencilOp(GL_KEEP, GL_INVERT, GL_KEEP);
                    glStencilMask(0x01);

                    i += RenderPolygonBatch(i);
                }
                else if (rp->PolyData->Translucent)
                {
                    bool needopaque = ((rp->PolyData->Attr & 0x001F0000) == 0x001F0000);

                    u32 polyattr = rp->PolyData->Attr;
                    u32 polyid = (polyattr >> 24) & 0x3F;

                    if (polyattr & (1<<14))
                        glDepthFunc(GL_LEQUAL);
                    else
                        glDepthFunc(GL_LESS);

                    if (needopaque)
                    {
                        UseRenderShader(flags);

                        glDisable(GL_BLEND);
                        glColorMaski(0, GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
                        glColorMaski(1, GL_TRUE, GL_TRUE, fogenable, GL_FALSE);

                        glStencilFunc(GL_ALWAYS, polyid, 0xFF);
                        glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
                        glStencilMask(0xFF);

                        glDepthMask(GL_TRUE);

                        RenderSinglePolygon(i);
                    }

                    UseRenderShader(flags | RenderFlag_Trans);

                    GLboolean transfog;
                    if (!(polyattr & (1<<15))) transfog = fogenable;
                    else                       transfog = GL_FALSE;

                    if (rp->PolyData->IsShadow)
                    {
                        // shadow against clear-plane will only pass if its polyID matches that of the clear plane
                        u32 clrpolyid = (gpu3d.RenderClearAttr1 >> 24) & 0x3F;
                        if (polyid != clrpolyid) { i++; continue; }

                        glEnable(GL_BLEND);
                        glColorMaski(0, GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
                        glColorMaski(1, GL_FALSE, GL_FALSE, transfog, GL_FALSE);

                        glStencilFunc(GL_EQUAL, 0xFE, 0xFF);
                        glStencilOp(GL_KEEP, GL_KEEP, GL_INVERT);
                        glStencilMask(~(0x40|polyid)); // heheh

                        if (polyattr & (1<<11)) glDepthMask(GL_TRUE);
                        else                    glDepthMask(GL_FALSE);

                        i += needopaque ? RenderSinglePolygon(i) : RenderPolygonBatch(i);
                    }
                    else
                    {
                        glColorMaski(0, GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
                        glColorMaski(1, GL_FALSE, GL_FALSE, transfog, GL_FALSE);

                        glStencilFunc(GL_EQUAL, 0xFF, 0xFE);
                        glStencilOp(GL_KEEP, GL_KEEP, GL_INVERT);
                        glStencilMask(~(0x40|polyid)); // heheh

                        if (polyattr & (1<<11)) glDepthMask(GL_TRUE);
                        else                    glDepthMask(GL_FALSE);

                        i += needopaque ? RenderSinglePolygon(i) : RenderPolygonBatch(i);
                    }
                }
                else
                    i++;
            }

            glEnable(GL_BLEND);
            glStencilMask(0xFF);
        }

        // pass 3: translucent pixels

        for (int i = 0; i < NumFinalPolys; )
        {
            RendererPolygon* rp = &PolygonList[i];

            if (rp->PolyData->IsShadowMask)
            {
                // clear shadow bits in stencil buffer

                glStencilMask(0x80);
                glClear(GL_STENCIL_BUFFER_BIT);

                // draw actual shadow mask

                UseRenderShader(flags | RenderFlag_ShadowMask);

                glDisable(GL_BLEND);
                glColorMaski(0, GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
                glColorMaski(1, GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
                glDepthMask(GL_FALSE);

                glDepthFunc(GL_LESS);
                glStencilFunc(GL_ALWAYS, 0x80, 0x80);
                glStencilOp(GL_KEEP, GL_REPLACE, GL_KEEP);

                i += RenderPolygonBatch(i);
            }
            else if (rp->PolyData->Translucent)
            {
                bool needopaque = ((rp->PolyData->Attr & 0x001F0000) == 0x001F0000);

                u32 polyattr = rp->PolyData->Attr;
                u32 polyid = (polyattr >> 24) & 0x3F;

                if (polyattr & (1<<14))
                    glDepthFunc(GL_LEQUAL);
                else
                    glDepthFunc(GL_LESS);

                if (needopaque)
                {
                    UseRenderShader(flags);

                    glDisable(GL_BLEND);
                    glColorMaski(0, GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
                    glColorMaski(1, GL_TRUE, GL_TRUE, fogenable, GL_FALSE);

                    glStencilFunc(GL_ALWAYS, polyid, 0xFF);
                    glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
                    glStencilMask(0xFF);

                    glDepthMask(GL_TRUE);

                    RenderSinglePolygon(i);
                }

                UseRenderShader(flags | RenderFlag_Trans);

                GLboolean transfog;
                if (!(polyattr & (1<<15))) transfog = fogenable;
                else                       transfog = GL_FALSE;

                if (rp->PolyData->IsShadow)
                {
                    glDisable(GL_BLEND);
                    glColorMaski(0, GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
                    glColorMaski(1, GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
                    glDepthMask(GL_FALSE);
                    glStencilFunc(GL_EQUAL, polyid, 0x3F);
                    glStencilOp(GL_KEEP, GL_KEEP, GL_ZERO);
                    glStencilMask(0x80);

                    RenderSinglePolygon(i);

                    glEnable(GL_BLEND);
                    glColorMaski(0, GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
                    glColorMaski(1, GL_FALSE, GL_FALSE, transfog, GL_FALSE);

                    glStencilFunc(GL_EQUAL, 0xC0|polyid, 0x80);
                    glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
                    glStencilMask(0x7F);

                    if (polyattr & (1<<11)) glDepthMask(GL_TRUE);
                    else                    glDepthMask(GL_FALSE);

                    i += RenderSinglePolygon(i);
                }
                else
                {
                    glEnable(GL_BLEND);
                    glColorMaski(0, GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
                    glColorMaski(1, GL_FALSE, GL_FALSE, transfog, GL_FALSE);

                    glStencilFunc(GL_NOTEQUAL, 0x40|polyid, 0x7F);
                    glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
                    glStencilMask(0x7F);

                    if (polyattr & (1<<11)) glDepthMask(GL_TRUE);
                    else                    glDepthMask(GL_FALSE);

                    i += needopaque ? RenderSinglePolygon(i) : RenderPolygonBatch(i);
                }
            }
            else
                i++;
        }
    }

    if (gpu3d.RenderDispCnt & 0x00A0) // fog/edge enabled
    {
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, FinalPassFramebuffer);
        glColorMaski(0, GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        glColorMaski(1, GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);

        glEnable(GL_BLEND);
        glBlendEquationSeparate(GL_FUNC_ADD, GL_FUNC_ADD);

        glDepthFunc(GL_ALWAYS);
        glDepthMask(GL_FALSE);
        glStencilFunc(GL_ALWAYS, 0, 0);
        glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP);
        glStencilMask(0);

        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, DepthBufferTex);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, AttrBufferTex);

        glBindBuffer(GL_ARRAY_BUFFER, ClearVertexBufferID);
        glBindVertexArray(ClearVertexArrayID);

        if (gpu3d.RenderDispCnt & (1<<5))
        {
            // edge marking
            // TODO: depth/polyid values at screen edges

            glUseProgram(FinalPassEdgeShader);

            glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ZERO, GL_ONE);

            glDrawArrays(GL_TRIANGLES, 0, 2*3);
        }

        if (gpu3d.RenderDispCnt & (1<<7))
        {
            // fog

            glUseProgram(FinalPassFogShader);

            if (gpu3d.RenderDispCnt & (1<<6))
                glBlendFuncSeparate(GL_ZERO, GL_ONE, GL_CONSTANT_COLOR, GL_ONE_MINUS_SRC_ALPHA);
            else
                glBlendFuncSeparate(GL_CONSTANT_COLOR, GL_ONE_MINUS_SRC_ALPHA, GL_CONSTANT_COLOR, GL_ONE_MINUS_SRC_ALPHA);

            {
                u32 c = gpu3d.RenderFogColor;
                u32 r = c & 0x1F;
                u32 g = (c >> 5) & 0x1F;
                u32 b = (c >> 10) & 0x1F;
                u32 a = (c >> 16) & 0x1F;

                glBlendColor((float)b/31.0, (float)g/31.0, (float)r/31.0, (float)a/31.0);
            }

            glDrawArrays(GL_TRIANGLES, 0, 2*3);
        }
    }
}


void GLRenderer::RenderFrame(GPU& gpu)
{
    // PokeDaisy: a frame no one will see (fast-forward's skip) isn't drawn.
    if (gpu.SkippingFrame)
        return;

    CurShaderID = -1;

    // PokeDaisy: EXPAND's list and view, else the game's own.
    const WidePolygonList* wide = (Wide && Wide->Active) ? Wide : nullptr;
    Polygon* const* polygonRAM = wide ? wide->Polygons : gpu.GPU3D.RenderPolygonRAM.data();
    u32 numPolygons = wide ? (u32)wide->NumPolygons : gpu.GPU3D.RenderNumPolygons;
    if (numPolygons > (u32)MaxPolygons) numPolygons = MaxPolygons;
    CurScale = wide ? wide->Scale : ScaleFactor;
    CurColor ^= 1;
    View& view = Rendered[CurColor];
    // The list's whole view, and the part of it drawn (the colour texture holds that part only; the viewport is the
    // whole view, moved so the part lands at (0, 0)).
    int fullW = wide ? wide->ViewW : 256, fullH = wide ? wide->ViewH : 192;
    bool crop = wide && wide->CropW > 0 && wide->CropH > 0;
    int cropX = crop ? wide->CropX : 0, cropY = crop ? wide->CropY : 0;
    view.ViewW = crop ? wide->CropW : fullW;
    view.ViewH = crop ? wide->CropH : fullH;
    view.OffX = (wide ? wide->OffX : 0) - cropX;
    view.OffY = (wide ? wide->OffY : 0) - cropY;
    view.Scale = CurScale;
    ScreenW = view.ViewW * CurScale;
    ScreenH = view.ViewH * CurScale;
    EnsureTarget(ScreenW, ScreenH);

    glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, MainFramebuffer);

    ShaderConfig.uScreenSize[0] = fullW * CurScale;
    ShaderConfig.uScreenSize[1] = fullH * CurScale;
    ShaderConfig.uDispCnt = gpu.GPU3D.RenderDispCnt;

    for (int i = 0; i < 32; i++)
    {
        u16 c = gpu.GPU3D.RenderToonTable[i];
        u32 r = c & 0x1F;
        u32 g = (c >> 5) & 0x1F;
        u32 b = (c >> 10) & 0x1F;

        ShaderConfig.uToonColors[i][0] = (float)r / 31.0;
        ShaderConfig.uToonColors[i][1] = (float)g / 31.0;
        ShaderConfig.uToonColors[i][2] = (float)b / 31.0;
    }

    for (int i = 0; i < 8; i++)
    {
        u16 c = gpu.GPU3D.RenderEdgeTable[i];
        u32 r = c & 0x1F;
        u32 g = (c >> 5) & 0x1F;
        u32 b = (c >> 10) & 0x1F;

        ShaderConfig.uEdgeColors[i][0] = (float)r / 31.0;
        ShaderConfig.uEdgeColors[i][1] = (float)g / 31.0;
        ShaderConfig.uEdgeColors[i][2] = (float)b / 31.0;
    }

    {
        u32 c = gpu.GPU3D.RenderFogColor;
        u32 r = c & 0x1F;
        u32 g = (c >> 5) & 0x1F;
        u32 b = (c >> 10) & 0x1F;
        u32 a = (c >> 16) & 0x1F;

        ShaderConfig.uFogColor[0] = (float)r / 31.0;
        ShaderConfig.uFogColor[1] = (float)g / 31.0;
        ShaderConfig.uFogColor[2] = (float)b / 31.0;
        ShaderConfig.uFogColor[3] = (float)a / 31.0;
    }

    for (int i = 0; i < 34; i++)
    {
        u8 d = gpu.GPU3D.RenderFogDensityTable[i];
        ShaderConfig.uFogDensity[i][0] = (float)d / 127.0;
    }

    ShaderConfig.uFogOffset = gpu.GPU3D.RenderFogOffset;
    ShaderConfig.uFogShift = gpu.GPU3D.RenderFogShift;

    glBindBuffer(GL_UNIFORM_BUFFER, ShaderConfigUBO);
    glBufferSubData(GL_UNIFORM_BUFFER, 0, sizeof(ShaderConfig), &ShaderConfig);

    // SUCKY!!!!!!!!!!!!!!!!!!
    // TODO: detect when VRAM blocks are modified!
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, TexMemID);
    for (int i = 0; i < 4; i++)
    {
        u32 mask = gpu.VRAMMap_Texture[i];
        u8* vram;
        if (!mask) continue;
        else if (mask & (1<<0)) vram = gpu.VRAM_A;
        else if (mask & (1<<1)) vram = gpu.VRAM_B;
        else if (mask & (1<<2)) vram = gpu.VRAM_C;
        else if (mask & (1<<3)) vram = gpu.VRAM_D;

        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, i*128, 1024, 128, GL_RED_INTEGER, GL_UNSIGNED_BYTE, vram);
    }

    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, TexPalMemID);
    for (int i = 0; i < 6; i++)
    {
        // 6 x 16K chunks
        u32 mask = gpu.VRAMMap_TexPal[i];
        u8* vram;
        if (!mask) continue;
        else if (mask & (1<<4)) vram = &gpu.VRAM_E[(i&3)*0x4000];
        else if (mask & (1<<5)) vram = gpu.VRAM_F;
        else if (mask & (1<<6)) vram = gpu.VRAM_G;

        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, i*8, 1024, 8, GL_RED_INTEGER, GL_UNSIGNED_SHORT, vram);
    }

    glDisable(GL_SCISSOR_TEST);
    glEnable(GL_DEPTH_TEST);
    glEnable(GL_STENCIL_TEST);

    glViewport(-cropX * CurScale, -cropY * CurScale, fullW * CurScale, fullH * CurScale);

    glDisable(GL_BLEND);
    glColorMaski(0, GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glColorMaski(1, GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glDepthMask(GL_TRUE);
    glStencilMask(0xFF);

    // clear buffers
    // TODO: clear bitmap
    // TODO: check whether 'clear polygon ID' affects translucent polyID
    // (for example when alpha is 1..30)
    {
        glUseProgram(ClearShaderPlain);
        glDepthFunc(GL_ALWAYS);

        u32 r = gpu.GPU3D.RenderClearAttr1 & 0x1F;
        u32 g = (gpu.GPU3D.RenderClearAttr1 >> 5) & 0x1F;
        u32 b = (gpu.GPU3D.RenderClearAttr1 >> 10) & 0x1F;
        u32 fog = (gpu.GPU3D.RenderClearAttr1 >> 15) & 0x1;
        u32 a = (gpu.GPU3D.RenderClearAttr1 >> 16) & 0x1F;
        u32 polyid = (gpu.GPU3D.RenderClearAttr1 >> 24) & 0x3F;
        u32 z = ((gpu.GPU3D.RenderClearAttr2 & 0x7FFF) * 0x200) + 0x1FF;

        glStencilFunc(GL_ALWAYS, 0xFF, 0xFF);
        glStencilOp(GL_REPLACE, GL_REPLACE, GL_REPLACE);

        /*if (r) r = r*2 + 1;
        if (g) g = g*2 + 1;
        if (b) b = b*2 + 1;*/

        glUniform4ui(ClearUniformLoc[0], r, g, b, a);
        glUniform1ui(ClearUniformLoc[1], z);
        glUniform1ui(ClearUniformLoc[2], polyid);
        glUniform1ui(ClearUniformLoc[3], fog);

        glBindBuffer(GL_ARRAY_BUFFER, ClearVertexBufferID);
        glBindVertexArray(ClearVertexArrayID);
        glDrawArrays(GL_TRIANGLES, 0, 2*3);
    }

    if (numPolygons)
    {
        // render shit here
        int npolys = 0;
        int firsttrans = -1;
        for (u32 i = 0; i < numPolygons; i++)
        {
            if (polygonRAM[i]->Degenerate) continue;

            SetupPolygon(&PolygonList[npolys], polygonRAM[i]);
            if (firsttrans < 0 && polygonRAM[i]->Translucent)
                firsttrans = npolys;

            npolys++;
        }
        NumFinalPolys = npolys;
        NumOpaqueFinalPolys = firsttrans;

        BuildPolygons(&PolygonList[0], npolys);
        glBindBuffer(GL_ARRAY_BUFFER, VertexBufferID);
        glBufferSubData(GL_ARRAY_BUFFER, 0, NumVertices*7*4, VertexBuffer);

        // bind to access the index buffer
        glBindVertexArray(VertexArrayID);
        glBufferSubData(GL_ELEMENT_ARRAY_BUFFER, 0, NumIndices * 2, IndexBuffer);
        glBufferSubData(GL_ELEMENT_ARRAY_BUFFER, EdgeIndicesOffset * 2, NumEdgeIndices * 2, IndexBuffer + EdgeIndicesOffset);

        if (NumFinalPolys > 0)
            RenderSceneChunk(gpu.GPU3D, 0, 192);
    }
}

void GLRenderer::Stop(const GPU& gpu)
{
    CurGLCompositor.Stop(gpu);
}

void GLRenderer::PrepareCaptureFrame()
{
    glBindFramebuffer(GL_READ_FRAMEBUFFER, MainFramebuffer);
    glReadBuffer(GL_COLOR_ATTACHMENT0);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, DownscaleFramebuffer);
    GLenum bufferAttachment = GL_COLOR_ATTACHMENT0;
    glDrawBuffers(1, &bufferAttachment);
    // PokeDaisy: the game's own screen out of an EXPAND view
    const View& view = Rendered[CurColor];
    int s = view.Scale, x0 = view.OffX * s, y0 = view.OffY * s;
    glBlitFramebuffer(x0, y0, x0 + 256 * s, y0 + 192 * s, 0, 0, 256, 192, GL_COLOR_BUFFER_BIT, GL_NEAREST);

    glBindBuffer(GL_PIXEL_PACK_BUFFER, PixelbufferID);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, DownscaleFramebuffer);
#ifdef MELONDS_GLES
    glReadPixels(0, 0, 256, 192, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
#else
    glReadPixels(0, 0, 256, 192, GL_BGRA, GL_UNSIGNED_BYTE, NULL);
#endif
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
}

void GLRenderer::Blit(const GPU& gpu)
{
    if (BlitHook)
    {
        BlitHook(gpu, *this, BlitHookUser);
        return;
    }
    CurGLCompositor.RenderFrame(gpu, *this);
}

void GLRenderer::BindOutputTexture(int buffer)
{
    CurGLCompositor.BindOutputTexture(buffer);
}

u32* GLRenderer::GetLine(int line)
{
    int stride = 256;

    if (line == 0)
    {
        glBindBuffer(GL_PIXEL_PACK_BUFFER, PixelbufferID);
#ifdef MELONDS_GLES
        u8* data = (u8*)glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, 4*stride*192, GL_MAP_READ_BIT);
        if (data)
        {
            // read as RGBA: the colour texture holds B, G, R, A (the shaders write .bgra)
            u32* src = (u32*)data;
            for (int i = 0; i < stride*192; i++)
            {
                u32 c = src[i];
                Framebuffer[i] = (c & 0xFF00FF00) | ((c & 0xFF) << 16) | ((c >> 16) & 0xFF);
            }
        }
#else
        u8* data = (u8*)glMapBuffer(GL_PIXEL_PACK_BUFFER, GL_READ_ONLY);
        if (data) memcpy(&Framebuffer[stride*0], data, 4*stride*192);
#endif
        glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    }

    u64* ptr = (u64*)&Framebuffer[stride * line];
    for (int i = 0; i < stride; i+=2)
    {
        u64 rgb = *ptr & 0x00FCFCFC00FCFCFC;
        u64 a = *ptr & 0xF8000000F8000000;

        *ptr++ = (rgb >> 2) | (a >> 3);
    }

    return &Framebuffer[stride * line];
}

void GLRenderer::SetupAccelFrame()
{
    glBindTexture(GL_TEXTURE_2D, ColorBufferTex[CurColor]);
}

}
