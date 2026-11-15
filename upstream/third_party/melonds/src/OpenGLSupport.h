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

#ifndef OPENGLSUPPORT_H
#define OPENGLSUPPORT_H

#include <stdio.h>
#include <string.h>

#include "Platform.h"
#include "PlatformOGL.h"

#ifdef MELONDS_GLES
// PokeDaisy: OpenGL ES 3.0 and up. glColorMaski is ES 3.2's or OES / EXT_draw_buffers_indexed's: the host loads it into
// OpenGL::ColorMaski before a renderer starts. glFramebufferTexture (ES 3.2) is glFramebufferTexture2D here.
namespace melonDS::OpenGL { extern PFNGLCOLORMASKIPROC ColorMaski; }
#define glColorMaski melonDS::OpenGL::ColorMaski
#define glFramebufferTexture(target, attachment, texture, level) \
    glFramebufferTexture2D(target, attachment, GL_TEXTURE_2D, texture, level)
#endif

namespace melonDS::OpenGL
{

void LoadShaderCache();
void SaveShaderCache();

struct AttributeTarget
{
    const char* Name;
    u32 Location;
};


bool CompileVertexFragmentProgram(GLuint& result,
    const std::string& vs, const std::string& fs,
    const std::string& name,
    const std::initializer_list<AttributeTarget>& vertexInAttrs,
    const std::initializer_list<AttributeTarget>& fragmentOutAttrs);

bool CompileComputeProgram(GLuint& result, const std::string& source, const std::string& name);

}

#endif // OPENGLSUPPORT_H
