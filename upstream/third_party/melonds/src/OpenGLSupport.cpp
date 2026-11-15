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

#include "OpenGLSupport.h"

#include <unordered_map>
#include <vector>

#include <assert.h>

#define XXH_STATIC_LINKING_ONLY
#include "xxhash/xxhash.h"

namespace melonDS
{

using Platform::Log;
using Platform::LogLevel;

namespace OpenGL
{

#ifdef MELONDS_GLES
PFNGLCOLORMASKIPROC ColorMaski = nullptr;
#endif

struct ShaderCacheEntry
{
    u32 Length;
    u8* Data;
    u32 BinaryFormat;

    ShaderCacheEntry(u8* data, u32 length, u32 binaryFmt)
        : Length(length), Data(data), BinaryFormat(binaryFmt)
    {
        assert(data != nullptr);
    }

    ShaderCacheEntry(const ShaderCacheEntry&) = delete;
    ShaderCacheEntry(ShaderCacheEntry&& other)
    {
        Data = other.Data;
        Length = other.Length;
        BinaryFormat = other.BinaryFormat;

        other.Data = nullptr;
        other.Length = 0;
        other.BinaryFormat = 0;
    }

    ~ShaderCacheEntry()
    {
        if (Data) // check whether it was moved
            delete[] Data;
    }
};

std::unordered_map<u64, ShaderCacheEntry> ShaderCache;
std::vector<u64> NewShaders;

constexpr u32 ShaderCacheMagic = 0x11CAC4E1;
constexpr u32 ShaderCacheVersion = 1;

void LoadShaderCache()
{
    // for now the shader cache only contains only compute shaders
    // because they take the longest to compile
    Platform::FileHandle* file = Platform::OpenLocalFile("shadercache", Platform::FileMode::Read);
    if (file == nullptr)
    {
        Log(LogLevel::Error, "Could not find shader cache\n");
        return;
    }

    u32 magic, version, numPrograms;
    if (Platform::FileRead(&magic, 4, 1, file) != 1 || magic != ShaderCacheMagic)
    {
        Log(LogLevel::Error, "Shader cache file has invalid magic\n");
        goto fileInvalid;
    }

    if (Platform::FileRead(&version, 4, 1, file) != 1 || version != ShaderCacheVersion)
    {
        Log(LogLevel::Error, "Shader cache file has bad version\n");
        goto fileInvalid;
    }

    if (Platform::FileRead(&numPrograms, 4, 1, file) != 1)
    {
        Log(LogLevel::Error, "Shader cache file invalid program count\n");
        goto fileInvalid;
    }

    // not the best approach, because once changes pile up
    // we read and overwrite the old files
    for (u32 i = 0; i < numPrograms; i++)
    {
        int error = 3;

        u32 length, binaryFormat;
        u64 sourceHash;
        error -= Platform::FileRead(&sourceHash, 8, 1, file);
        error -= Platform::FileRead(&length, 4, 1, file);
        error -= Platform::FileRead(&binaryFormat, 4, 1, file);

        if (error != 0)
        {
            Log(LogLevel::Error, "Invalid shader cache entry\n");
            goto fileInvalid;
        }

        u8* data = new u8[length];
        if (Platform::FileRead(data, length, 1, file) != 1)
        {
            Log(LogLevel::Error, "Could not read shader cache entry data\n");
            delete[] data;
            goto fileInvalid;
        }

        ShaderCache.erase(sourceHash);
        ShaderCache.emplace(sourceHash, ShaderCacheEntry(data, length, binaryFormat));
    }

fileInvalid:
    Platform::CloseFile(file);
}

void SaveShaderCache()
{
    Platform::FileHandle* file = Platform::OpenLocalFile("shadercache", Platform::FileMode::ReadWrite);

    if (file == nullptr)
    {
        Log(LogLevel::Error, "Could not open or create shader cache file\n");
        return;
    }

    int written = 3;
    u32 magic = ShaderCacheMagic, version = ShaderCacheVersion, numPrograms = ShaderCache.size();
    written -= Platform::FileWrite(&magic, 4, 1, file);
    written -= Platform::FileWrite(&version, 4, 1, file);
    written -= Platform::FileWrite(&numPrograms, 4, 1, file);

    if (written != 0)
    {
        Log(LogLevel::Error, "Could not write shader cache header\n");
        goto writeError;
    }

    Platform::FileSeek(file, 0, Platform::FileSeekOrigin::End);

    printf("new shaders %zu\n", NewShaders.size());

    for (u64 newShader : NewShaders)
    {
        int error = 4;
        auto it = ShaderCache.find(newShader);

        error -= Platform::FileWrite(&it->first, 8, 1, file);
        error -= Platform::FileWrite(&it->second.Length, 4, 1, file);
        error -= Platform::FileWrite(&it->second.BinaryFormat, 4, 1, file);
        error -= Platform::FileWrite(it->second.Data, it->second.Length, 1, file);

        if (error != 0)
        {
            Log(LogLevel::Error, "Could not insert new shader cache entry\n");
            goto writeError;
        }
    }

writeError:
    Platform::CloseFile(file);

    NewShaders.clear();
}

#ifdef MELONDS_GLES
// PokeDaisy: the shaders are written for desktop GLSL 1.40; OpenGL ES 3 takes them with its own version line, default
// precisions, and the fragment outputs' locations in the source (ES has no glBindFragDataLocation).
static std::string ToGLES(const std::string& source, const std::initializer_list<AttributeTarget>& fragmentOutAttrs)
{
    std::string out = source;
    size_t v = out.find("#version");
    if (v != std::string::npos)
    {
        size_t eol = out.find('\n', v);
        out.replace(v, eol == std::string::npos ? std::string::npos : eol - v,
            "#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\n"
            "precision highp usampler2D;\nprecision highp isampler2D;");
    }
    for (const AttributeTarget& target : fragmentOutAttrs)
    {
        // "out vec4 oColor;" -> "layout(location = N) out vec4 oColor;"
        std::string name = std::string(" ") + target.Name + ";";
        for (size_t at = out.find(name); at != std::string::npos; at = out.find(name, at + 1))
        {
            size_t lineStart = out.rfind('\n', at);
            lineStart = lineStart == std::string::npos ? 0 : lineStart + 1;
            if (out.compare(lineStart, 4, "out ") != 0) continue;
            std::string layout = "layout(location = " + std::to_string(target.Location) + ") ";
            out.insert(lineStart, layout);
            break;
        }
    }
    return out;
}
#endif

bool CompilerShader(GLuint& id, const std::string& source, const std::string& name, const std::string& type)
{
    int res;

    const char* sourceC = source.c_str();
    int len = source.length();
    glShaderSource(id, 1, &sourceC, &len);

    glCompileShader(id);

    glGetShaderiv(id, GL_COMPILE_STATUS, &res);
    if (res != GL_TRUE)
    {
        glGetShaderiv(id, GL_INFO_LOG_LENGTH, &res);
        if (res < 1) res = 1024;
        char* log = new char[res+1];
        glGetShaderInfoLog(id, res+1, NULL, log);
        Log(LogLevel::Error, "OpenGL: failed to compile %s shader %s: %s\n", type.c_str(), name.c_str(), log);
        Log(LogLevel::Debug, "shader source:\n--\n%s\n--\n", source.c_str());
        delete[] log;

        glDeleteShader(id);

        return false;
    }

    return true;
}

bool LinkProgram(GLuint& result, GLuint* ids, int numIds)
{
    int res;

    for (int i = 0; i < numIds; i++)
    {
        glAttachShader(result, ids[i]);
    }

    glLinkProgram(result);

    for (int i = 0; i < numIds; i++)
        glDetachShader(result, ids[i]);

    glGetProgramiv(result, GL_LINK_STATUS, &res);
    if (res != GL_TRUE)
    {
        glGetProgramiv(result, GL_INFO_LOG_LENGTH, &res);
        if (res < 1) res = 1024;
        char* log = new char[res+1];
        glGetProgramInfoLog(result, res+1, NULL, log);
        Log(LogLevel::Error, "OpenGL: failed to link shader program: %s\n", log);
        delete[] log;

        return false;
    }

    return true;
}

bool CompileComputeProgram(GLuint& result, const std::string& source, const std::string& name)
{
    result = glCreateProgram();

    /*u64 sourceHash = XXH64(source.data(), source.size(), 0);
    auto it = ShaderCache.find(sourceHash);
    if (it != ShaderCache.end())
    {
        glProgramBinary(result, it->second.BinaryFormat, it->second.Data, it->second.Length);

        GLint linkStatus;
        glGetProgramiv(result, GL_LINK_STATUS, &linkStatus);
        if (linkStatus == GL_TRUE)
        {
            Log(LogLevel::Info, "Restored shader %s from cache\n", name.c_str());
            return true;
        }
        else
        {
        }
    }*/
    Log(LogLevel::Error, "Shader %s from cache was rejected\n", name.c_str());

    GLuint shader;
    bool linkingSucess = false;

    shader = glCreateShader(GL_COMPUTE_SHADER);

    if (!CompilerShader(shader, source, name, "compute"))
        goto error;

    linkingSucess = LinkProgram(result, &shader, 1);

error:
    glDeleteShader(shader);

    if (!linkingSucess)
    {
        glDeleteProgram(result);
    }
    /*else
    {
        GLint length;
        GLenum format;
        glGetProgramiv(result, GL_PROGRAM_BINARY_LENGTH, &length);

        u8* buffer = new u8[length];
        glGetProgramBinary(result, length, nullptr, &format, buffer);

        ShaderCache.emplace(sourceHash, ShaderCacheEntry(buffer, length, format));
        NewShaders.push_back(sourceHash);
    }*/

    return linkingSucess;
}

bool CompileVertexFragmentProgram(GLuint& result,
    const std::string& vs, const std::string& fs,
    const std::string& name,
    const std::initializer_list<AttributeTarget>& vertexInAttrs,
    const std::initializer_list<AttributeTarget>& fragmentOutAttrs)
{
    GLuint shaders[2] =
    {
        glCreateShader(GL_VERTEX_SHADER),
        glCreateShader(GL_FRAGMENT_SHADER)
    };
    result = glCreateProgram();

    bool linkingSucess = false;

#ifdef MELONDS_GLES
    if (!CompilerShader(shaders[0], ToGLES(vs, {}), name, "vertex"))
        goto error;

    if (!CompilerShader(shaders[1], ToGLES(fs, fragmentOutAttrs), name, "fragment"))
        goto error;
#else
    if (!CompilerShader(shaders[0], vs, name, "vertex"))
        goto error;

    if (!CompilerShader(shaders[1], fs, name, "fragment"))
        goto error;
#endif


    for (const AttributeTarget& target : vertexInAttrs)
    {
        glBindAttribLocation(result, target.Location, target.Name);
    }
#ifndef MELONDS_GLES
    for (const AttributeTarget& target : fragmentOutAttrs)
    {
        glBindFragDataLocation(result, target.Location, target.Name);
    }
#endif

    linkingSucess = LinkProgram(result, shaders, 2);

error:
    glDeleteShader(shaders[1]);
    glDeleteShader(shaders[0]);

    if (!linkingSucess)
        glDeleteProgram(result);

    return linkingSucess;
}

}

}