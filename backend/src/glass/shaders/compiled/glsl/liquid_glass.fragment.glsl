#version 300 es
precision highp float;
precision highp int;

uniform highp vec4 uData[55];
uniform highp sampler2D uSampler;
uniform highp sampler2D uTex1;

in highp vec4 vColor;
in highp vec2 vTextureCoord;
layout(location = 0) out highp vec4 out_var_SV_Target0;

void main()
{
    highp vec4 _678;
    do
    {
        int _90 = int((vColor.y * 255.0) + 0.5);
        int _95 = int((vColor.z * 255.0) + 0.5);
        bool _111 = uData[5].y > 0.0;
        highp float _113;
        highp float _116;
        highp vec2 _118;
        highp vec2 _120;
        highp vec4 _122;
        highp vec4 _124;
        highp float _126;
        highp float _128;
        highp float _130;
        highp float _132;
        _113 = 1000000000.0;
        _116 = 1000000000.0;
        _118 = vec2(0.0);
        _120 = vec2(0.0);
        _122 = vec4(0.0);
        _124 = vec4(0.0);
        _126 = 1000000000.0;
        _128 = 1000000000.0;
        _130 = 1000000000.0;
        _132 = 1000000000.0;
        highp float _117;
        highp vec2 _121;
        highp vec4 _125;
        highp float _129;
        highp float _133;
        highp float _114;
        highp vec2 _119;
        highp vec4 _123;
        highp float _127;
        highp float _131;
        int _134 = _90;
        for (;;)
        {
            bool _143;
            if (_134 < (_90 + _95))
            {
                _143 = _134 < 16;
            }
            else
            {
                _143 = false;
            }
            if (_143)
            {
                int _145 = 3 * _134;
                int _146 = 7 + _145;
                int _152 = _145 + 9;
                highp vec2 _156 = vTextureCoord - uData[_146 * 1 + 0].xy;
                highp float _160 = min(uData[_146 * 1 + 0].z, uData[_146 * 1 + 0].w);
                highp vec4 _162 = min(uData[(_145 + 8) * 1 + 0], vec4(_160));
                highp float _163 = _156.x;
                highp float _184;
                if (_163 > 0.0)
                {
                    highp float _175;
                    if (_156.y > 0.0)
                    {
                        _175 = _162.z;
                    }
                    else
                    {
                        _175 = _162.y;
                    }
                    _184 = _175;
                }
                else
                {
                    highp float _183;
                    if (_156.y > 0.0)
                    {
                        _183 = _162.w;
                    }
                    else
                    {
                        _183 = _162.x;
                    }
                    _184 = _183;
                }
                highp vec2 _188 = (abs(_156) - uData[_146 * 1 + 0].zw) + vec2(_184);
                highp float _190 = (_163 < 0.0) ? (-1.0) : 1.0;
                highp float _193 = (_156.y < 0.0) ? (-1.0) : 1.0;
                highp float _195 = _188.x;
                bool _201;
                if (_195 > 0.0)
                {
                    _201 = _188.y > 0.0;
                }
                else
                {
                    _201 = false;
                }
                highp vec2 _215;
                if (_201)
                {
                    _215 = normalize(_188) * vec2(_190, _193);
                }
                else
                {
                    highp vec2 _214;
                    if (_195 > _188.y)
                    {
                        _214 = vec2(_190, 0.0);
                    }
                    else
                    {
                        _214 = vec2(0.0, _193);
                    }
                    _215 = _214;
                }
                highp float _222 = (min(max(_195, _188.y), 0.0) + length(max(_188, vec2(0.0)))) - _184;
                bool _223 = _222 < _132;
                if (_223)
                {
                    _114 = _116;
                    _123 = _124;
                    _131 = _132;
                }
                else
                {
                    bool _227 = _222 < _130;
                    bvec4 _229 = bvec4(_227);
                    _114 = _227 ? _160 : _113;
                    _123 = vec4(_229.x ? uData[_152 * 1 + 0].x : _122.x, _229.y ? uData[_152 * 1 + 0].y : _122.y, _229.z ? uData[_152 * 1 + 0].z : _122.z, _229.w ? uData[_152 * 1 + 0].w : _122.w);
                    _131 = _227 ? _222 : _130;
                }
                _117 = _223 ? _160 : _116;
                bvec4 _232 = bvec4(_223);
                _125 = vec4(_232.x ? uData[_152 * 1 + 0].x : _124.x, _232.y ? uData[_152 * 1 + 0].y : _124.y, _232.z ? uData[_152 * 1 + 0].z : _124.z, _232.w ? uData[_152 * 1 + 0].w : _124.w);
                _133 = _223 ? _222 : _132;
                highp vec2 _277;
                highp float _278;
                if (uData[_152 * 1 + 0].w < 0.5)
                {
                    highp float _243 = (vTextureCoord.x - uData[_146 * 1 + 0].x) + uData[_146 * 1 + 0].z;
                    highp float _245 = (uData[_146 * 1 + 0].x + uData[_146 * 1 + 0].z) - vTextureCoord.x;
                    highp float _250 = (vTextureCoord.y - uData[_146 * 1 + 0].y) + uData[_146 * 1 + 0].w;
                    highp float _252 = (uData[_146 * 1 + 0].y + uData[_146 * 1 + 0].w) - vTextureCoord.y;
                    highp float _256 = min(min(_243, _245), min(_250, _252));
                    highp vec4 _261 = exp((vec4(_256) - vec4(_243, _245, _250, _252)) / vec4(uData[1].y));
                    highp float _262 = _261.x;
                    highp float _263 = _261.y;
                    highp float _265 = _261.z;
                    highp float _267 = _261.w;
                    highp float _268 = ((_262 + _263) + _265) + _267;
                    _277 = vec2(_263 - _262, _267 - _265) / vec2(_268);
                    _278 = (uData[1].y * log(_268)) - _256;
                }
                else
                {
                    _277 = _215;
                    _278 = _222;
                }
                bool _279 = _278 < _128;
                if (_279)
                {
                    _119 = _120;
                    _127 = _128;
                }
                else
                {
                    bool _283 = _278 < _126;
                    bvec2 _284 = bvec2(_283);
                    _119 = vec2(_284.x ? _277.x : _118.x, _284.y ? _277.y : _118.y);
                    _127 = _283 ? _278 : _126;
                }
                bvec2 _287 = bvec2(_279);
                _121 = vec2(_287.x ? _277.x : _120.x, _287.y ? _277.y : _120.y);
                _129 = _279 ? _278 : _128;
                _113 = _114;
                _116 = _117;
                _118 = _119;
                _120 = _121;
                _122 = _123;
                _124 = _125;
                _126 = _127;
                _128 = _129;
                _130 = _131;
                _132 = _133;
                _134++;
                continue;
            }
            else
            {
                break;
            }
        }
        highp float _289 = max(uData[1].x, 9.9999997473787516355514526367188e-05);
        highp float _294 = max(_289 - abs(_132 - _130), 0.0) / _289;
        highp float _295 = _294 * _294;
        highp float _296 = _295 * 0.5;
        highp float _301;
        if (_130 < _132)
        {
            _301 = 1.0 - _296;
        }
        else
        {
            _301 = _296;
        }
        highp float _305 = min(_132, _130) - ((_295 * _289) * 0.25);
        highp float _310 = max(_289 - abs(_128 - _126), 0.0) / _289;
        highp float _311 = _310 * _310;
        highp float _312 = _311 * 0.5;
        highp float _317;
        if (_126 < _128)
        {
            _317 = 1.0 - _312;
        }
        else
        {
            _317 = _312;
        }
        highp float _323 = clamp(0.5 - _305, 0.0, 1.0);
        if (_323 <= 0.0)
        {
            discard;
        }
        if (vColor.x < 0.5)
        {
            _678 = vec4(0.0, 0.0, 0.0, _323);
            break;
        }
        highp vec4 _334 = mix(_124, _122, vec4(_301));
        highp vec2 _336 = mix(_120, _118, vec2(_317));
        highp float _338 = max(0.0, -(min(_128, _126) - ((_311 * _289) * 0.25)));
        highp float _339 = -_338;
        highp float _342 = exp(_339 / uData[1].z);
        highp float _348 = _334.y;
        highp float _382;
        highp float _383;
        highp vec2 _384;
        if (_111)
        {
            highp float _356 = max(min(uData[5].y * mix(_116, _113, _301), uData[6].w), 1.0);
            highp float _359 = clamp(1.0 - (_338 / _356), 0.0, 1.0);
            highp float _364 = (((uData[5].z * _356) * _348) * _359) * _359;
            _382 = _359;
            _383 = _364;
            _384 = clamp(((vTextureCoord - (_336 * _364)) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        else
        {
            _382 = 0.0;
            _383 = 0.0;
            _384 = clamp(((vTextureCoord + (_336 * ((uData[2].x * _348) * _342))) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        highp vec4 _388 = textureLod(uSampler, _384, 0.0);
        bool _390 = uData[4].w > 0.5;
        highp vec4 _398;
        if (_390)
        {
            _398 = textureLod(uTex1, _384, 0.0);
        }
        else
        {
            _398 = _388;
        }
        bool _403;
        if (_111)
        {
            _403 = uData[6].y > 0.0;
        }
        else
        {
            _403 = false;
        }
        bool _407;
        if (_403)
        {
            _407 = _383 > 0.5;
        }
        else
        {
            _407 = false;
        }
        highp vec4 _468;
        highp vec4 _469;
        if (_407)
        {
            highp vec2 _415 = (_336 * ((_383 * 0.039999999105930328369140625) * uData[6].y)) * uData[0].zw;
            highp vec2 _417 = clamp(_384 + _415, vec2(0.0), vec2(1.0));
            highp vec2 _419 = clamp(_384 - _415, vec2(0.0), vec2(1.0));
            highp vec4 _423 = textureLod(uSampler, _417, 0.0);
            highp float _428 = _388.w;
            highp float _429 = (_423.x / max(_423.w, 9.9999997473787516355514526367188e-05)) * _428;
            highp vec4 _430 = _388;
            _430.x = _429;
            highp vec4 _434 = textureLod(uSampler, _419, 0.0);
            highp float _439 = (_434.z / max(_434.w, 9.9999997473787516355514526367188e-05)) * _428;
            _430.z = _439;
            highp vec4 _467;
            if (_390)
            {
                highp vec4 _447 = textureLod(uTex1, _417, 0.0);
                highp vec4 _454 = _398;
                _454.x = (_447.x / max(_447.w, 9.9999997473787516355514526367188e-05)) * _398.w;
                highp vec4 _458 = textureLod(uTex1, _419, 0.0);
                _454.z = (_458.z / max(_458.w, 9.9999997473787516355514526367188e-05)) * _398.w;
                _467 = _454;
            }
            else
            {
                highp vec4 _465 = _398;
                _465.x = _429;
                _465.z = _439;
                _467 = _465;
            }
            _468 = _467;
            _469 = _430;
        }
        else
        {
            _468 = _398;
            _469 = _388;
        }
        highp float _477;
        if (uData[6].x > 0.5)
        {
            _477 = 1.0;
        }
        else
        {
            _477 = _469.w;
        }
        highp vec4 _486 = vec4(_469.xyz / vec3(max(_469.w, 9.9999997473787516355514526367188e-05)), 1.0);
        highp vec4 _495 = vec4(_468.xyz / vec3(max(_468.w, 9.9999997473787516355514526367188e-05)), 1.0);
        bool _497 = uData[4].z > 0.5;
        highp float _502;
        if (_497)
        {
            _502 = uData[4].x;
        }
        else
        {
            _502 = 0.0;
        }
        highp float _511;
        if (_111)
        {
            _511 = _502 * (1.0 - ((_382 * _382) * (1.0 - smoothstep(0.800000011920928955078125, 1.0, _502))));
        }
        else
        {
            _511 = _502;
        }
        highp float _514 = 1.0 - _511;
        highp float _522;
        if (_111)
        {
            _522 = _382;
        }
        else
        {
            _522 = _342 * _342;
        }
        highp float _525 = clamp(((uData[2].y * _348) * _522) * _514, 0.0, 1.0);
        highp vec4 _531 = ((_495 * _525) + ((mix(_495, _486, vec4(clamp(_334.x, 0.0, 1.0))) * _514) * (1.0 - _525))) + (uData[3] * _511);
        highp float _536 = dot(_336, vec2(-0.707106769084930419921875));
        highp float _537 = max(_536, 0.0);
        highp float _539 = max(-_536, 0.0);
        highp float _542 = abs(_536);
        bool _547;
        if (_111)
        {
            _547 = uData[6].z > 0.0;
        }
        else
        {
            _547 = false;
        }
        highp float _567;
        if (_547)
        {
            _567 = (uData[6].z * (1.0 - smoothstep(0.20000000298023223876953125, 0.699999988079071044921875, _542))) * exp((-max(0.0, -_305)) / (uData[2].z * 2.5));
        }
        else
        {
            _567 = 0.85000002384185791015625 * (1.0 - smoothstep(0.0, uData[2].z * 0.625, -_305));
        }
        highp float _575;
        if (_111)
        {
            _575 = max((uData[5].w * _382) * _382, _567);
        }
        else
        {
            _575 = 0.0;
        }
        highp float _578 = _477 * (1.0 - _575);
        highp vec4 _584 = vec4((_531 + (_486 * (1.0 - _531.w))).xyz * _578, _578 + _575);
        highp float _603;
        if (_111)
        {
            highp float _594;
            if (_547)
            {
                _594 = uData[6].z * smoothstep(0.75, 1.0, _542);
            }
            else
            {
                _594 = 0.25;
            }
            _603 = _594;
        }
        else
        {
            _603 = (0.449999988079071044921875 * ((_537 * sqrt(_537)) + ((0.75 * _539) * sqrt(_539)))) + 0.0599999986588954925537109375;
        }
        highp float _630;
        if (_547)
        {
            _630 = exp((-max(0.0, -_305)) / (uData[2].z * 1.25));
        }
        else
        {
            highp float _629;
            if (_111)
            {
                highp float _617 = -_305;
                _629 = smoothstep(uData[2].z * 0.3125, uData[2].z * 0.625, _617) * (1.0 - smoothstep(uData[2].z * 1.5, uData[2].z * 2.0, _617));
            }
            else
            {
                _629 = exp((-max(0.0, -_305)) / uData[2].z);
            }
            _630 = _629;
        }
        highp float _637;
        if (_111)
        {
            _637 = 0.0;
        }
        else
        {
            _637 = (0.039999999105930328369140625 * exp(_339 / uData[1].w)) * _537;
        }
        highp float _643;
        if (_497)
        {
            _643 = uData[4].y;
        }
        else
        {
            _643 = 0.0;
        }
        highp vec3 _653 = _584.xyz + vec3(clamp((_643 + _334.z) + ((_348 * uData[2].w) * ((_630 * _603) + _637)), 0.0, 1.0));
        highp vec4 _655 = clamp(vec4(_653.x, _653.y, _653.z, _584.w), vec4(0.0), vec4(1.0));
        highp float _662 = max(_655.w, max(_655.x, max(_655.y, _655.z)));
        highp vec4 _663 = _655;
        _663.w = _662;
        highp vec3 _674 = _663.xyz + vec3(((fract(52.98291778564453125 * fract(dot(vTextureCoord, vec2(0.067110560834407806396484375, 0.005837149918079376220703125)))) - 0.5) * uData[5].x) * _662);
        _678 = clamp(vec4(_674.x, _674.y, _674.z, _663.w), vec4(0.0), vec4(1.0)) * _323;
        break;
    } while(false);
    out_var_SV_Target0 = _678;
}

