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
    highp vec4 _829;
    do
    {
        int _94 = int((vColor.y * 255.0) + 0.5);
        int _99 = int((vColor.z * 255.0) + 0.5);
        bool _115 = uData[5].y > 0.0;
        highp float _117;
        highp vec2 _120;
        highp vec4 _122;
        highp vec2 _124;
        highp float _126;
        highp float _128;
        highp vec4 _130;
        highp float _132;
        highp float _134;
        highp float _136;
        _117 = 1000000000.0;
        _120 = vec2(0.0);
        _122 = vec4(0.0);
        _124 = vec2(0.0);
        _126 = 1000000000.0;
        _128 = 1000000000.0;
        _130 = vec4(0.0);
        _132 = 1000000000.0;
        _134 = 1000000000.0;
        _136 = 1000000000.0;
        highp vec2 _125;
        highp float _129;
        highp vec4 _131;
        highp float _135;
        highp float _137;
        highp float _118;
        highp vec2 _121;
        highp vec4 _123;
        highp float _127;
        highp float _133;
        int _138 = _94;
        for (;;)
        {
            bool _147;
            if (_138 < (_94 + _99))
            {
                _147 = _138 < 16;
            }
            else
            {
                _147 = false;
            }
            if (_147)
            {
                int _149 = 3 * _138;
                int _150 = 7 + _149;
                int _156 = _149 + 9;
                highp vec2 _160 = vTextureCoord - uData[_150 * 1 + 0].xy;
                highp float _164 = min(uData[_150 * 1 + 0].z, uData[_150 * 1 + 0].w);
                highp vec4 _166 = min(uData[(_149 + 8) * 1 + 0], vec4(_164));
                highp float _167 = _160.x;
                highp float _188;
                if (_167 > 0.0)
                {
                    highp float _179;
                    if (_160.y > 0.0)
                    {
                        _179 = _166.z;
                    }
                    else
                    {
                        _179 = _166.y;
                    }
                    _188 = _179;
                }
                else
                {
                    highp float _187;
                    if (_160.y > 0.0)
                    {
                        _187 = _166.w;
                    }
                    else
                    {
                        _187 = _166.x;
                    }
                    _188 = _187;
                }
                highp vec2 _192 = (abs(_160) - uData[_150 * 1 + 0].zw) + vec2(_188);
                highp float _194 = (_167 < 0.0) ? (-1.0) : 1.0;
                highp float _197 = (_160.y < 0.0) ? (-1.0) : 1.0;
                highp float _199 = _192.x;
                bool _205;
                if (_199 > 0.0)
                {
                    _205 = _192.y > 0.0;
                }
                else
                {
                    _205 = false;
                }
                highp vec2 _219;
                if (_205)
                {
                    _219 = normalize(_192) * vec2(_194, _197);
                }
                else
                {
                    highp vec2 _218;
                    if (_199 > _192.y)
                    {
                        _218 = vec2(_194, 0.0);
                    }
                    else
                    {
                        _218 = vec2(0.0, _197);
                    }
                    _219 = _218;
                }
                highp float _226 = (min(max(_199, _192.y), 0.0) + length(max(_192, vec2(0.0)))) - _188;
                bool _227 = _226 < _134;
                if (_227)
                {
                    _118 = _136;
                    _123 = _130;
                    _133 = _134;
                }
                else
                {
                    bool _231 = _226 < _132;
                    bvec4 _233 = bvec4(_231);
                    _118 = _231 ? _164 : _117;
                    _123 = vec4(_233.x ? uData[_156 * 1 + 0].x : _122.x, _233.y ? uData[_156 * 1 + 0].y : _122.y, _233.z ? uData[_156 * 1 + 0].z : _122.z, _233.w ? uData[_156 * 1 + 0].w : _122.w);
                    _133 = _231 ? _226 : _132;
                }
                bvec4 _236 = bvec4(_227);
                _131 = vec4(_236.x ? uData[_156 * 1 + 0].x : _130.x, _236.y ? uData[_156 * 1 + 0].y : _130.y, _236.z ? uData[_156 * 1 + 0].z : _130.z, _236.w ? uData[_156 * 1 + 0].w : _130.w);
                _135 = _227 ? _226 : _134;
                _137 = _227 ? _164 : _136;
                highp vec2 _281;
                highp float _282;
                if (uData[_156 * 1 + 0].w < 0.5)
                {
                    highp float _247 = (vTextureCoord.x - uData[_150 * 1 + 0].x) + uData[_150 * 1 + 0].z;
                    highp float _249 = (uData[_150 * 1 + 0].x + uData[_150 * 1 + 0].z) - vTextureCoord.x;
                    highp float _254 = (vTextureCoord.y - uData[_150 * 1 + 0].y) + uData[_150 * 1 + 0].w;
                    highp float _256 = (uData[_150 * 1 + 0].y + uData[_150 * 1 + 0].w) - vTextureCoord.y;
                    highp float _260 = min(min(_247, _249), min(_254, _256));
                    highp vec4 _265 = exp((vec4(_260) - vec4(_247, _249, _254, _256)) / vec4(uData[1].y));
                    highp float _266 = _265.x;
                    highp float _267 = _265.y;
                    highp float _269 = _265.z;
                    highp float _271 = _265.w;
                    highp float _272 = ((_266 + _267) + _269) + _271;
                    _281 = vec2(_267 - _266, _271 - _269) / vec2(_272);
                    _282 = (uData[1].y * log(_272)) - _260;
                }
                else
                {
                    _281 = _219;
                    _282 = _226;
                }
                bool _283 = _282 < _128;
                if (_283)
                {
                    _121 = _124;
                    _127 = _128;
                }
                else
                {
                    bool _287 = _282 < _126;
                    bvec2 _288 = bvec2(_287);
                    _121 = vec2(_288.x ? _281.x : _120.x, _288.y ? _281.y : _120.y);
                    _127 = _287 ? _282 : _126;
                }
                bvec2 _291 = bvec2(_283);
                _125 = vec2(_291.x ? _281.x : _124.x, _291.y ? _281.y : _124.y);
                _129 = _283 ? _282 : _128;
                _117 = _118;
                _120 = _121;
                _122 = _123;
                _124 = _125;
                _126 = _127;
                _128 = _129;
                _130 = _131;
                _132 = _133;
                _134 = _135;
                _136 = _137;
                _138++;
                continue;
            }
            else
            {
                break;
            }
        }
        highp float _400;
        highp vec2 _401;
        highp vec2 _402;
        highp vec4 _403;
        highp vec4 _404;
        highp float _405;
        highp float _406;
        highp float _407;
        highp float _408;
        highp float _409;
        if (uData[54].w > 1.5)
        {
            highp vec2 _303 = vTextureCoord - uData[52].xy;
            highp vec4 _309 = min(uData[53], vec4(min(uData[52].z, uData[52].w)));
            highp float _310 = _303.x;
            highp float _331;
            if (_310 > 0.0)
            {
                highp float _322;
                if (_303.y > 0.0)
                {
                    _322 = _309.z;
                }
                else
                {
                    _322 = _309.y;
                }
                _331 = _322;
            }
            else
            {
                highp float _330;
                if (_303.y > 0.0)
                {
                    _330 = _309.w;
                }
                else
                {
                    _330 = _309.x;
                }
                _331 = _330;
            }
            highp vec2 _335 = (abs(_303) - uData[52].zw) + vec2(_331);
            highp float _337 = (_310 < 0.0) ? (-1.0) : 1.0;
            highp float _340 = (_303.y < 0.0) ? (-1.0) : 1.0;
            highp float _342 = _335.x;
            bool _348;
            if (_342 > 0.0)
            {
                _348 = _335.y > 0.0;
            }
            else
            {
                _348 = false;
            }
            highp vec2 _362;
            if (_348)
            {
                _362 = normalize(_335) * vec2(_337, _340);
            }
            else
            {
                highp vec2 _361;
                if (_342 > _335.y)
                {
                    _361 = vec2(_337, 0.0);
                }
                else
                {
                    _361 = vec2(0.0, _340);
                }
                _362 = _361;
            }
            highp float _369 = (min(max(_342, _335.y), 0.0) + length(max(_335, vec2(0.0)))) - _331;
            highp float _370 = 1.0 - _369;
            bool _371 = _370 < _134;
            highp float _380;
            highp vec4 _381;
            highp float _382;
            if (_371)
            {
                _380 = _136;
                _381 = _130;
                _382 = _134;
            }
            else
            {
                bool _375 = _370 < _132;
                bvec4 _377 = bvec4(_375);
                _380 = _375 ? _136 : _117;
                _381 = vec4(_377.x ? uData[54].x : _122.x, _377.y ? uData[54].y : _122.y, _377.z ? uData[54].z : _122.z, _377.w ? uData[54].w : _122.w);
                _382 = _375 ? _370 : _132;
            }
            bvec4 _383 = bvec4(_371);
            highp vec2 _386 = -_362;
            bool _387 = _370 < _128;
            highp vec2 _395;
            highp float _396;
            if (_387)
            {
                _395 = _124;
                _396 = _128;
            }
            else
            {
                bool _391 = _370 < _126;
                bvec2 _392 = bvec2(_391);
                _395 = vec2(_392.x ? _386.x : _120.x, _392.y ? _386.y : _120.y);
                _396 = _391 ? _370 : _126;
            }
            bvec2 _397 = bvec2(_387);
            _400 = _380;
            _401 = _395;
            _402 = vec2(_397.x ? _386.x : _124.x, _397.y ? _386.y : _124.y);
            _403 = _381;
            _404 = vec4(_383.x ? uData[54].x : _130.x, _383.y ? uData[54].y : _130.y, _383.z ? uData[54].z : _130.z, _383.w ? uData[54].w : _130.w);
            _405 = _369;
            _406 = _396;
            _407 = _387 ? _370 : _128;
            _408 = _382;
            _409 = _371 ? _370 : _134;
        }
        else
        {
            _400 = _117;
            _401 = _120;
            _402 = _124;
            _403 = _122;
            _404 = _130;
            _405 = -1000000000.0;
            _406 = _126;
            _407 = _128;
            _408 = _132;
            _409 = _134;
        }
        highp float _411 = max(uData[1].x, 9.9999997473787516355514526367188e-05);
        highp float _416 = max(_411 - abs(_409 - _408), 0.0) / _411;
        highp float _417 = _416 * _416;
        highp float _418 = _417 * 0.5;
        highp float _423;
        if (_408 < _409)
        {
            _423 = 1.0 - _418;
        }
        else
        {
            _423 = _418;
        }
        highp float _427 = min(_409, _408) - ((_417 * _411) * 0.25);
        highp float _432 = max(_411 - abs(_407 - _406), 0.0) / _411;
        highp float _433 = _432 * _432;
        highp float _434 = _433 * 0.5;
        highp float _439;
        if (_406 < _407)
        {
            _439 = 1.0 - _434;
        }
        else
        {
            _439 = _434;
        }
        highp float _446 = clamp(0.5 - max(_427, _405), 0.0, 1.0);
        if (_446 <= 0.0)
        {
            discard;
        }
        if (vColor.x < 0.5)
        {
            _829 = vec4(0.0, 0.0, 0.0, _446);
            break;
        }
        highp vec4 _457 = mix(_404, _403, vec4(_423));
        highp vec2 _459 = mix(_402, _401, vec2(_439));
        highp float _461 = max(0.0, -(min(_407, _406) - ((_433 * _411) * 0.25)));
        highp float _462 = -_461;
        highp float _465 = exp(_462 / uData[1].z);
        highp float _471 = _457.y;
        highp float _505;
        highp float _506;
        highp vec2 _507;
        if (_115)
        {
            highp float _479 = max(min(uData[5].y * mix(_136, _400, _423), uData[6].w), 1.0);
            highp float _482 = clamp(1.0 - (_461 / _479), 0.0, 1.0);
            highp float _487 = (((uData[5].z * _479) * _471) * _482) * _482;
            _505 = _482;
            _506 = _487;
            _507 = clamp(((vTextureCoord - (_459 * _487)) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        else
        {
            _505 = 0.0;
            _506 = 0.0;
            _507 = clamp(((vTextureCoord + (_459 * ((uData[2].x * _471) * _465))) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        highp vec4 _511 = textureLod(uSampler, _507, 0.0);
        bool _513 = uData[4].w > 0.5;
        highp vec4 _521;
        if (_513)
        {
            _521 = textureLod(uTex1, _507, 0.0);
        }
        else
        {
            _521 = _511;
        }
        bool _526;
        if (_115)
        {
            _526 = uData[6].y > 0.0;
        }
        else
        {
            _526 = false;
        }
        bool _530;
        if (_526)
        {
            _530 = _506 > 0.5;
        }
        else
        {
            _530 = false;
        }
        highp vec4 _591;
        highp vec4 _592;
        if (_530)
        {
            highp vec2 _538 = (_459 * ((_506 * 0.039999999105930328369140625) * uData[6].y)) * uData[0].zw;
            highp vec2 _540 = clamp(_507 + _538, vec2(0.0), vec2(1.0));
            highp vec2 _542 = clamp(_507 - _538, vec2(0.0), vec2(1.0));
            highp vec4 _546 = textureLod(uSampler, _540, 0.0);
            highp float _551 = _511.w;
            highp float _552 = (_546.x / max(_546.w, 9.9999997473787516355514526367188e-05)) * _551;
            highp vec4 _553 = _511;
            _553.x = _552;
            highp vec4 _557 = textureLod(uSampler, _542, 0.0);
            highp float _562 = (_557.z / max(_557.w, 9.9999997473787516355514526367188e-05)) * _551;
            _553.z = _562;
            highp vec4 _590;
            if (_513)
            {
                highp vec4 _570 = textureLod(uTex1, _540, 0.0);
                highp vec4 _577 = _521;
                _577.x = (_570.x / max(_570.w, 9.9999997473787516355514526367188e-05)) * _521.w;
                highp vec4 _581 = textureLod(uTex1, _542, 0.0);
                _577.z = (_581.z / max(_581.w, 9.9999997473787516355514526367188e-05)) * _521.w;
                _590 = _577;
            }
            else
            {
                highp vec4 _588 = _521;
                _588.x = _552;
                _588.z = _562;
                _590 = _588;
            }
            _591 = _590;
            _592 = _553;
        }
        else
        {
            _591 = _521;
            _592 = _511;
        }
        bool _594 = uData[4].x > 1.5;
        highp float _607;
        if (_594)
        {
            _607 = uData[3].w;
        }
        else
        {
            highp float _606;
            if (uData[6].x > 0.5)
            {
                _606 = 1.0;
            }
            else
            {
                _606 = _592.w;
            }
            _607 = _606;
        }
        highp vec4 _616 = vec4(_592.xyz / vec3(max(_592.w, 9.9999997473787516355514526367188e-05)), 1.0);
        highp vec4 _625 = vec4(_591.xyz / vec3(max(_591.w, 9.9999997473787516355514526367188e-05)), 1.0);
        highp float _632;
        if (_594)
        {
            _632 = 1.0;
        }
        else
        {
            _632 = (uData[4].z > 0.5) ? uData[4].x : 0.0;
        }
        bool _636;
        if (_115)
        {
            _636 = !_594;
        }
        else
        {
            _636 = false;
        }
        highp float _645;
        if (_636)
        {
            _645 = _632 * (1.0 - ((_505 * _505) * (1.0 - smoothstep(0.800000011920928955078125, 1.0, _632))));
        }
        else
        {
            _645 = _632;
        }
        highp float _648 = 1.0 - _645;
        highp float _656;
        if (_115)
        {
            _656 = _505;
        }
        else
        {
            _656 = _465 * _465;
        }
        highp float _659 = clamp(((uData[2].y * _471) * _656) * _648, 0.0, 1.0);
        highp vec4 _665 = ((_625 * _659) + ((mix(_625, _616, vec4(clamp(_457.x, 0.0, 1.0))) * _648) * (1.0 - _659))) + (uData[3] * _645);
        highp vec4 _682;
        if (_594)
        {
            _682 = vec4(uData[3].xyz / vec3(max(uData[3].w, 9.9999997473787516355514526367188e-05)), 1.0);
        }
        else
        {
            _682 = _665 + (_616 * (1.0 - _665.w));
        }
        highp float _683 = dot(_459, vec2(-0.707106769084930419921875));
        highp float _684 = max(_683, 0.0);
        highp float _686 = max(-_683, 0.0);
        highp float _689 = abs(_683);
        bool _694;
        if (_115)
        {
            _694 = uData[6].z > 0.0;
        }
        else
        {
            _694 = false;
        }
        highp float _714;
        if (_694)
        {
            _714 = (uData[6].z * (1.0 - smoothstep(0.20000000298023223876953125, 0.699999988079071044921875, _689))) * exp((-max(0.0, -_427)) / (uData[2].z * 2.5));
        }
        else
        {
            _714 = 0.85000002384185791015625 * (1.0 - smoothstep(0.0, uData[2].z * 0.625, -_427));
        }
        highp float _724;
        if (_115)
        {
            _724 = max((uData[5].w * _505) * _505, _714) * min(_471, 1.0);
        }
        else
        {
            _724 = 0.0;
        }
        highp float _727 = _607 * (1.0 - _724);
        highp vec4 _733 = vec4(_682.xyz * _727, _727 + _724);
        highp float _752;
        if (_115)
        {
            highp float _743;
            if (_694)
            {
                _743 = uData[6].z * smoothstep(0.75, 1.0, _689);
            }
            else
            {
                _743 = 0.25;
            }
            _752 = _743;
        }
        else
        {
            _752 = (0.449999988079071044921875 * ((_684 * sqrt(_684)) + ((0.75 * _686) * sqrt(_686)))) + 0.0599999986588954925537109375;
        }
        highp float _779;
        if (_694)
        {
            _779 = exp((-max(0.0, -_427)) / (uData[2].z * 1.25));
        }
        else
        {
            highp float _778;
            if (_115)
            {
                highp float _766 = -_427;
                _778 = smoothstep(uData[2].z * 0.3125, uData[2].z * 0.625, _766) * (1.0 - smoothstep(uData[2].z * 1.5, uData[2].z * 2.0, _766));
            }
            else
            {
                _778 = exp((-max(0.0, -_427)) / uData[2].z);
            }
            _779 = _778;
        }
        highp float _786;
        if (_115)
        {
            _786 = 0.0;
        }
        else
        {
            _786 = (0.039999999105930328369140625 * exp(_462 / uData[1].w)) * _684;
        }
        highp float _794;
        if (uData[4].z > 0.5)
        {
            _794 = uData[4].y;
        }
        else
        {
            _794 = 0.0;
        }
        highp vec3 _804 = _733.xyz + vec3(clamp((_794 + _457.z) + ((_471 * uData[2].w) * ((_779 * _752) + _786)), 0.0, 1.0));
        highp vec4 _806 = clamp(vec4(_804.x, _804.y, _804.z, _733.w), vec4(0.0), vec4(1.0));
        highp float _813 = max(_806.w, max(_806.x, max(_806.y, _806.z)));
        highp vec4 _814 = _806;
        _814.w = _813;
        highp vec3 _825 = _814.xyz + vec3(((fract(52.98291778564453125 * fract(dot(vTextureCoord, vec2(0.067110560834407806396484375, 0.005837149918079376220703125)))) - 0.5) * uData[5].x) * _813);
        _829 = clamp(vec4(_825.x, _825.y, _825.z, _814.w), vec4(0.0), vec4(1.0)) * _446;
        break;
    } while(false);
    out_var_SV_Target0 = _829;
}

