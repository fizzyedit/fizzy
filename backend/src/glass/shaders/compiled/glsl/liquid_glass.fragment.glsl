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
    highp vec4 _853;
    do
    {
        int _96 = int((vColor.y * 255.0) + 0.5);
        int _101 = int((vColor.z * 255.0) + 0.5);
        bool _117 = uData[5].y > 0.0;
        highp float _119;
        highp vec2 _122;
        highp vec4 _124;
        highp vec2 _126;
        highp float _128;
        highp float _130;
        highp vec4 _132;
        highp float _134;
        highp float _136;
        highp float _138;
        _119 = 1000000000.0;
        _122 = vec2(0.0);
        _124 = vec4(0.0);
        _126 = vec2(0.0);
        _128 = 1000000000.0;
        _130 = 1000000000.0;
        _132 = vec4(0.0);
        _134 = 1000000000.0;
        _136 = 1000000000.0;
        _138 = 1000000000.0;
        highp vec2 _127;
        highp float _131;
        highp vec4 _133;
        highp float _137;
        highp float _139;
        highp float _120;
        highp vec2 _123;
        highp vec4 _125;
        highp float _129;
        highp float _135;
        int _140 = _96;
        for (;;)
        {
            bool _149;
            if (_140 < (_96 + _101))
            {
                _149 = _140 < 16;
            }
            else
            {
                _149 = false;
            }
            if (_149)
            {
                int _151 = 3 * _140;
                int _152 = 7 + _151;
                int _158 = _151 + 9;
                highp vec2 _162 = vTextureCoord - uData[_152 * 1 + 0].xy;
                highp float _166 = min(uData[_152 * 1 + 0].z, uData[_152 * 1 + 0].w);
                highp vec4 _168 = min(uData[(_151 + 8) * 1 + 0], vec4(_166));
                highp float _169 = _162.x;
                highp float _190;
                if (_169 > 0.0)
                {
                    highp float _181;
                    if (_162.y > 0.0)
                    {
                        _181 = _168.z;
                    }
                    else
                    {
                        _181 = _168.y;
                    }
                    _190 = _181;
                }
                else
                {
                    highp float _189;
                    if (_162.y > 0.0)
                    {
                        _189 = _168.w;
                    }
                    else
                    {
                        _189 = _168.x;
                    }
                    _190 = _189;
                }
                highp vec2 _194 = (abs(_162) - uData[_152 * 1 + 0].zw) + vec2(_190);
                highp float _196 = (_169 < 0.0) ? (-1.0) : 1.0;
                highp float _199 = (_162.y < 0.0) ? (-1.0) : 1.0;
                highp float _201 = _194.x;
                bool _207;
                if (_201 > 0.0)
                {
                    _207 = _194.y > 0.0;
                }
                else
                {
                    _207 = false;
                }
                highp vec2 _221;
                if (_207)
                {
                    _221 = normalize(_194) * vec2(_196, _199);
                }
                else
                {
                    highp vec2 _220;
                    if (_201 > _194.y)
                    {
                        _220 = vec2(_196, 0.0);
                    }
                    else
                    {
                        _220 = vec2(0.0, _199);
                    }
                    _221 = _220;
                }
                highp float _228 = (min(max(_201, _194.y), 0.0) + length(max(_194, vec2(0.0)))) - _190;
                bool _229 = _228 < _136;
                if (_229)
                {
                    _120 = _138;
                    _125 = _132;
                    _135 = _136;
                }
                else
                {
                    bool _233 = _228 < _134;
                    bvec4 _235 = bvec4(_233);
                    _120 = _233 ? _166 : _119;
                    _125 = vec4(_235.x ? uData[_158 * 1 + 0].x : _124.x, _235.y ? uData[_158 * 1 + 0].y : _124.y, _235.z ? uData[_158 * 1 + 0].z : _124.z, _235.w ? uData[_158 * 1 + 0].w : _124.w);
                    _135 = _233 ? _228 : _134;
                }
                bvec4 _238 = bvec4(_229);
                _133 = vec4(_238.x ? uData[_158 * 1 + 0].x : _132.x, _238.y ? uData[_158 * 1 + 0].y : _132.y, _238.z ? uData[_158 * 1 + 0].z : _132.z, _238.w ? uData[_158 * 1 + 0].w : _132.w);
                _137 = _229 ? _228 : _136;
                _139 = _229 ? _166 : _138;
                highp vec2 _283;
                highp float _284;
                if (uData[_158 * 1 + 0].w < 0.5)
                {
                    highp float _249 = (vTextureCoord.x - uData[_152 * 1 + 0].x) + uData[_152 * 1 + 0].z;
                    highp float _251 = (uData[_152 * 1 + 0].x + uData[_152 * 1 + 0].z) - vTextureCoord.x;
                    highp float _256 = (vTextureCoord.y - uData[_152 * 1 + 0].y) + uData[_152 * 1 + 0].w;
                    highp float _258 = (uData[_152 * 1 + 0].y + uData[_152 * 1 + 0].w) - vTextureCoord.y;
                    highp float _262 = min(min(_249, _251), min(_256, _258));
                    highp vec4 _267 = exp((vec4(_262) - vec4(_249, _251, _256, _258)) / vec4(uData[1].y));
                    highp float _268 = _267.x;
                    highp float _269 = _267.y;
                    highp float _271 = _267.z;
                    highp float _273 = _267.w;
                    highp float _274 = ((_268 + _269) + _271) + _273;
                    _283 = vec2(_269 - _268, _273 - _271) / vec2(_274);
                    _284 = (uData[1].y * log(_274)) - _262;
                }
                else
                {
                    _283 = _221;
                    _284 = _228;
                }
                bool _285 = _284 < _130;
                if (_285)
                {
                    _123 = _126;
                    _129 = _130;
                }
                else
                {
                    bool _289 = _284 < _128;
                    bvec2 _290 = bvec2(_289);
                    _123 = vec2(_290.x ? _283.x : _122.x, _290.y ? _283.y : _122.y);
                    _129 = _289 ? _284 : _128;
                }
                bvec2 _293 = bvec2(_285);
                _127 = vec2(_293.x ? _283.x : _126.x, _293.y ? _283.y : _126.y);
                _131 = _285 ? _284 : _130;
                _119 = _120;
                _122 = _123;
                _124 = _125;
                _126 = _127;
                _128 = _129;
                _130 = _131;
                _132 = _133;
                _134 = _135;
                _136 = _137;
                _138 = _139;
                _140++;
                continue;
            }
            else
            {
                break;
            }
        }
        bool _297 = uData[54].w > 2.5;
        bool _298 = uData[54].w > 1.5;
        highp float _373;
        highp vec2 _374;
        if (_298)
        {
            highp vec2 _306 = vTextureCoord - uData[52].xy;
            highp vec4 _312 = min(uData[53], vec4(min(uData[52].z, uData[52].w)));
            highp float _313 = _306.x;
            highp float _334;
            if (_313 > 0.0)
            {
                highp float _325;
                if (_306.y > 0.0)
                {
                    _325 = _312.z;
                }
                else
                {
                    _325 = _312.y;
                }
                _334 = _325;
            }
            else
            {
                highp float _333;
                if (_306.y > 0.0)
                {
                    _333 = _312.w;
                }
                else
                {
                    _333 = _312.x;
                }
                _334 = _333;
            }
            highp vec2 _338 = (abs(_306) - uData[52].zw) + vec2(_334);
            highp float _340 = (_313 < 0.0) ? (-1.0) : 1.0;
            highp float _343 = (_306.y < 0.0) ? (-1.0) : 1.0;
            highp float _345 = _338.x;
            bool _351;
            if (_345 > 0.0)
            {
                _351 = _338.y > 0.0;
            }
            else
            {
                _351 = false;
            }
            highp vec2 _365;
            if (_351)
            {
                _365 = normalize(_338) * vec2(_340, _343);
            }
            else
            {
                highp vec2 _364;
                if (_345 > _338.y)
                {
                    _364 = vec2(_340, 0.0);
                }
                else
                {
                    _364 = vec2(0.0, _343);
                }
                _365 = _364;
            }
            _373 = (min(max(_345, _338.y), 0.0) + length(max(_338, vec2(0.0)))) - _334;
            _374 = _365;
        }
        else
        {
            _373 = -1000000000.0;
            _374 = vec2(0.0);
        }
        bool _378;
        if (_298)
        {
            _378 = !_297;
        }
        else
        {
            _378 = false;
        }
        highp float _411;
        highp vec2 _412;
        highp vec2 _413;
        highp vec4 _414;
        highp vec4 _415;
        highp float _416;
        highp float _417;
        highp float _418;
        highp float _419;
        if (_378)
        {
            highp float _381 = 1.0 - _373;
            bool _382 = _381 < _136;
            highp float _391;
            highp vec4 _392;
            highp float _393;
            if (_382)
            {
                _391 = _138;
                _392 = _132;
                _393 = _136;
            }
            else
            {
                bool _386 = _381 < _134;
                bvec4 _388 = bvec4(_386);
                _391 = _386 ? _138 : _119;
                _392 = vec4(_388.x ? uData[54].x : _124.x, _388.y ? uData[54].y : _124.y, _388.z ? uData[54].z : _124.z, _388.w ? uData[54].w : _124.w);
                _393 = _386 ? _381 : _134;
            }
            bvec4 _394 = bvec4(_382);
            highp vec2 _397 = -_374;
            bool _398 = _381 < _130;
            highp vec2 _406;
            highp float _407;
            if (_398)
            {
                _406 = _126;
                _407 = _130;
            }
            else
            {
                bool _402 = _381 < _128;
                bvec2 _403 = bvec2(_402);
                _406 = vec2(_403.x ? _397.x : _122.x, _403.y ? _397.y : _122.y);
                _407 = _402 ? _381 : _128;
            }
            bvec2 _408 = bvec2(_398);
            _411 = _391;
            _412 = _406;
            _413 = vec2(_408.x ? _397.x : _126.x, _408.y ? _397.y : _126.y);
            _414 = _392;
            _415 = vec4(_394.x ? uData[54].x : _132.x, _394.y ? uData[54].y : _132.y, _394.z ? uData[54].z : _132.z, _394.w ? uData[54].w : _132.w);
            _416 = _407;
            _417 = _398 ? _381 : _130;
            _418 = _393;
            _419 = _382 ? _381 : _136;
        }
        else
        {
            _411 = _119;
            _412 = _122;
            _413 = _126;
            _414 = _124;
            _415 = _132;
            _416 = _128;
            _417 = _130;
            _418 = _134;
            _419 = _136;
        }
        highp float _421 = max(uData[1].x, 9.9999997473787516355514526367188e-05);
        highp float _426 = max(_421 - abs(_419 - _418), 0.0) / _421;
        highp float _427 = _426 * _426;
        highp float _428 = _427 * 0.5;
        highp float _433;
        if (_418 < _419)
        {
            _433 = 1.0 - _428;
        }
        else
        {
            _433 = _428;
        }
        highp float _437 = min(_419, _418) - ((_427 * _421) * 0.25);
        highp float _442 = max(_421 - abs(_417 - _416), 0.0) / _421;
        highp float _443 = _442 * _442;
        highp float _444 = _443 * 0.5;
        highp float _449;
        if (_416 < _417)
        {
            _449 = 1.0 - _444;
        }
        else
        {
            _449 = _444;
        }
        highp float _453 = min(_417, _416) - ((_443 * _421) * 0.25);
        highp float _457;
        if (_297)
        {
            _457 = max(_437, _373);
        }
        else
        {
            _457 = _437;
        }
        highp float _460 = clamp(0.5 - max(_457, _373), 0.0, 1.0);
        if (_460 <= 0.0)
        {
            discard;
        }
        if (vColor.x < 0.5)
        {
            _853 = vec4(0.0, 0.0, 0.0, _460);
            break;
        }
        highp vec4 _471 = mix(_415, _414, vec4(_433));
        highp vec2 _473 = mix(_413, _412, vec2(_449));
        bool _477;
        if (_297)
        {
            _477 = _373 > _453;
        }
        else
        {
            _477 = false;
        }
        bvec2 _478 = bvec2(_477);
        highp vec2 _479 = vec2(_478.x ? _374.x : _473.x, _478.y ? _374.y : _473.y);
        highp float _482 = max(0.0, -(_477 ? _373 : _453));
        highp float _483 = -_482;
        highp float _486 = exp(_483 / uData[1].z);
        highp float _492 = _471.y;
        highp float _526;
        highp float _527;
        highp vec2 _528;
        if (_117)
        {
            highp float _500 = max(min(uData[5].y * mix(_138, _411, _433), uData[6].w), 1.0);
            highp float _503 = clamp(1.0 - (_482 / _500), 0.0, 1.0);
            highp float _508 = (((uData[5].z * _500) * _492) * _503) * _503;
            _526 = _503;
            _527 = _508;
            _528 = clamp(((vTextureCoord - (_479 * _508)) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        else
        {
            _526 = 0.0;
            _527 = 0.0;
            _528 = clamp(((vTextureCoord + (_479 * ((uData[2].x * _492) * _486))) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        highp vec4 _532 = textureLod(uSampler, _528, 0.0);
        bool _534 = uData[4].w > 0.5;
        highp vec4 _542;
        if (_534)
        {
            _542 = textureLod(uTex1, _528, 0.0);
        }
        else
        {
            _542 = _532;
        }
        bool _547;
        if (_117)
        {
            _547 = uData[6].y > 0.0;
        }
        else
        {
            _547 = false;
        }
        bool _551;
        if (_547)
        {
            _551 = _527 > 0.5;
        }
        else
        {
            _551 = false;
        }
        highp vec4 _612;
        highp vec4 _613;
        if (_551)
        {
            highp vec2 _559 = (_479 * ((_527 * 0.039999999105930328369140625) * uData[6].y)) * uData[0].zw;
            highp vec2 _561 = clamp(_528 + _559, vec2(0.0), vec2(1.0));
            highp vec2 _563 = clamp(_528 - _559, vec2(0.0), vec2(1.0));
            highp vec4 _567 = textureLod(uSampler, _561, 0.0);
            highp float _572 = _532.w;
            highp float _573 = (_567.x / max(_567.w, 9.9999997473787516355514526367188e-05)) * _572;
            highp vec4 _574 = _532;
            _574.x = _573;
            highp vec4 _578 = textureLod(uSampler, _563, 0.0);
            highp float _583 = (_578.z / max(_578.w, 9.9999997473787516355514526367188e-05)) * _572;
            _574.z = _583;
            highp vec4 _611;
            if (_534)
            {
                highp vec4 _591 = textureLod(uTex1, _561, 0.0);
                highp vec4 _598 = _542;
                _598.x = (_591.x / max(_591.w, 9.9999997473787516355514526367188e-05)) * _542.w;
                highp vec4 _602 = textureLod(uTex1, _563, 0.0);
                _598.z = (_602.z / max(_602.w, 9.9999997473787516355514526367188e-05)) * _542.w;
                _611 = _598;
            }
            else
            {
                highp vec4 _609 = _542;
                _609.x = _573;
                _609.z = _583;
                _611 = _609;
            }
            _612 = _611;
            _613 = _574;
        }
        else
        {
            _612 = _542;
            _613 = _532;
        }
        bool _615 = uData[4].x > 1.5;
        highp float _629;
        if (_615)
        {
            _629 = uData[3].w;
        }
        else
        {
            highp float _628;
            if ((uData[6].x - 2.0 * trunc(uData[6].x / 2.0)) > 0.5)
            {
                _628 = 1.0;
            }
            else
            {
                _628 = _613.w;
            }
            _629 = _628;
        }
        highp vec4 _638 = vec4(_613.xyz / vec3(max(_613.w, 9.9999997473787516355514526367188e-05)), 1.0);
        highp vec4 _647 = vec4(_612.xyz / vec3(max(_612.w, 9.9999997473787516355514526367188e-05)), 1.0);
        highp float _654;
        if (_615)
        {
            _654 = 1.0;
        }
        else
        {
            _654 = (uData[4].z > 0.5) ? uData[4].x : 0.0;
        }
        bool _658;
        if (_117)
        {
            _658 = !_615;
        }
        else
        {
            _658 = false;
        }
        highp float _667;
        if (_658)
        {
            _667 = _654 * (1.0 - ((_526 * _526) * (1.0 - smoothstep(0.800000011920928955078125, 1.0, _654))));
        }
        else
        {
            _667 = _654;
        }
        highp float _670 = 1.0 - _667;
        highp float _678;
        if (_117)
        {
            _678 = _526;
        }
        else
        {
            _678 = _486 * _486;
        }
        highp float _681 = clamp(((uData[2].y * _492) * _678) * _670, 0.0, 1.0);
        highp vec4 _687 = ((_647 * _681) + ((mix(_647, _638, vec4(clamp(_471.x, 0.0, 1.0))) * _670) * (1.0 - _681))) + (uData[3] * _667);
        highp vec4 _704;
        if (_615)
        {
            _704 = vec4(uData[3].xyz / vec3(max(uData[3].w, 9.9999997473787516355514526367188e-05)), 1.0);
        }
        else
        {
            _704 = _687 + (_638 * (1.0 - _687.w));
        }
        bvec2 _707 = bvec2(uData[6].x > 1.5);
        highp float _710 = dot(_479, vec2(_707.x ? vec2(0.707106769084930419921875, -0.707106769084930419921875).x : vec2(-0.707106769084930419921875).x, _707.y ? vec2(0.707106769084930419921875, -0.707106769084930419921875).y : vec2(-0.707106769084930419921875).y));
        highp float _711 = max(_710, 0.0);
        highp float _713 = max(-_710, 0.0);
        highp float _716 = abs(_710);
        bool _720;
        if (_117)
        {
            _720 = uData[6].z > 0.0;
        }
        else
        {
            _720 = false;
        }
        highp float _739;
        if (_720)
        {
            _739 = (uData[6].z * (1.0 - smoothstep(0.20000000298023223876953125, 0.699999988079071044921875, _716))) * exp((-max(0.0, -_457)) / (uData[2].z * 2.5));
        }
        else
        {
            _739 = 0.85000002384185791015625 * (1.0 - smoothstep(0.0, uData[2].z * 0.625, -_457));
        }
        highp float _749;
        if (_117)
        {
            _749 = max((uData[5].w * _526) * _526, _739) * min(_492, 1.0);
        }
        else
        {
            _749 = 0.0;
        }
        highp float _752 = _629 * (1.0 - _749);
        highp vec4 _758 = vec4(_704.xyz * _752, _752 + _749);
        highp float _776;
        if (_117)
        {
            highp float _767;
            if (_720)
            {
                _767 = uData[6].z * smoothstep(0.75, 1.0, _716);
            }
            else
            {
                _767 = 0.25;
            }
            _776 = _767;
        }
        else
        {
            _776 = (0.449999988079071044921875 * ((_711 * sqrt(_711)) + ((0.75 * _713) * sqrt(_713)))) + 0.0599999986588954925537109375;
        }
        highp float _803;
        if (_720)
        {
            _803 = exp((-max(0.0, -_457)) / (uData[2].z * 1.25));
        }
        else
        {
            highp float _802;
            if (_117)
            {
                highp float _790 = -_457;
                _802 = smoothstep(uData[2].z * 0.3125, uData[2].z * 0.625, _790) * (1.0 - smoothstep(uData[2].z * 1.5, uData[2].z * 2.0, _790));
            }
            else
            {
                _802 = exp((-max(0.0, -_457)) / uData[2].z);
            }
            _803 = _802;
        }
        highp float _810;
        if (_117)
        {
            _810 = 0.0;
        }
        else
        {
            _810 = (0.039999999105930328369140625 * exp(_483 / uData[1].w)) * _711;
        }
        highp float _818;
        if (uData[4].z > 0.5)
        {
            _818 = uData[4].y;
        }
        else
        {
            _818 = 0.0;
        }
        highp vec3 _828 = _758.xyz + vec3(clamp((_818 + _471.z) + ((_492 * uData[2].w) * ((_803 * _776) + _810)), 0.0, 1.0));
        highp vec4 _830 = clamp(vec4(_828.x, _828.y, _828.z, _758.w), vec4(0.0), vec4(1.0));
        highp float _837 = max(_830.w, max(_830.x, max(_830.y, _830.z)));
        highp vec4 _838 = _830;
        _838.w = _837;
        highp vec3 _849 = _838.xyz + vec3(((fract(52.98291778564453125 * fract(dot(vTextureCoord, vec2(0.067110560834407806396484375, 0.005837149918079376220703125)))) - 0.5) * uData[5].x) * _837);
        _853 = clamp(vec4(_849.x, _849.y, _849.z, _838.w), vec4(0.0), vec4(1.0)) * _460;
        break;
    } while(false);
    out_var_SV_Target0 = _853;
}

