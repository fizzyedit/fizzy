#version 300 es
precision highp float;
precision highp int;

uniform highp vec4 uData[59];
uniform highp sampler2D uSampler;
uniform highp sampler2D uTex1;

in highp vec4 vColor;
in highp vec2 vTextureCoord;
layout(location = 0) out highp vec4 out_var_SV_Target0;

void main()
{
    highp vec4 _1186;
    do
    {
        int _107 = int((vColor.y * 255.0) + 0.5);
        int _112 = int((vColor.z * 255.0) + 0.5);
        bool _136 = uData[5].y > 0.0;
        highp vec2 _138;
        highp float _141;
        highp vec2 _143;
        highp vec2 _145;
        highp vec4 _147;
        highp vec2 _149;
        highp float _151;
        highp float _153;
        highp vec2 _155;
        highp vec2 _157;
        highp vec4 _159;
        highp float _161;
        highp float _163;
        highp float _165;
        _138 = vec2(0.0, 1.0);
        _141 = 1000000000.0;
        _143 = vec2(0.0);
        _145 = vec2(0.0);
        _147 = vec4(0.0);
        _149 = vec2(0.0);
        _151 = 1000000000.0;
        _153 = 1000000000.0;
        _155 = vec2(0.0);
        _157 = vec2(0.0, 1.0);
        _159 = vec4(0.0);
        _161 = 1000000000.0;
        _163 = 1000000000.0;
        _165 = 1000000000.0;
        highp vec2 _150;
        highp float _154;
        highp vec2 _156;
        highp vec4 _160;
        highp float _164;
        highp float _166;
        highp vec2 _139;
        highp float _142;
        highp vec2 _144;
        highp vec2 _146;
        highp vec4 _148;
        highp float _152;
        highp vec2 _158;
        highp float _162;
        int _167 = _107;
        for (;;)
        {
            bool _176;
            if (_167 < (_107 + _112))
            {
                _176 = _167 < 16;
            }
            else
            {
                _176 = false;
            }
            if (_176)
            {
                int _178 = 3 * _167;
                int _179 = 11 + _178;
                int _185 = _178 + 13;
                highp float _190 = min(uData[_179 * 1 + 0].z, uData[_179 * 1 + 0].w);
                highp vec4 _192 = min(uData[(_178 + 12) * 1 + 0], vec4(_190));
                highp vec2 _194 = vTextureCoord - uData[_179 * 1 + 0].xy;
                highp float _196 = _194.x;
                highp float _217;
                if (_196 > 0.0)
                {
                    highp float _208;
                    if (_194.y > 0.0)
                    {
                        _208 = _192.z;
                    }
                    else
                    {
                        _208 = _192.y;
                    }
                    _217 = _208;
                }
                else
                {
                    highp float _216;
                    if (_194.y > 0.0)
                    {
                        _216 = _192.w;
                    }
                    else
                    {
                        _216 = _192.x;
                    }
                    _217 = _216;
                }
                highp vec2 _221 = (abs(_194) - uData[_179 * 1 + 0].zw) + vec2(_217);
                highp float _223 = (_196 < 0.0) ? (-1.0) : 1.0;
                highp float _226 = (_194.y < 0.0) ? (-1.0) : 1.0;
                highp float _228 = _221.x;
                bool _234;
                if (_228 > 0.0)
                {
                    _234 = _221.y > 0.0;
                }
                else
                {
                    _234 = false;
                }
                highp vec2 _248;
                if (_234)
                {
                    _248 = normalize(_221) * vec2(_223, _226);
                }
                else
                {
                    highp vec2 _247;
                    if (_228 > _221.y)
                    {
                        _247 = vec2(_223, 0.0);
                    }
                    else
                    {
                        _247 = vec2(0.0, _226);
                    }
                    _248 = _247;
                }
                highp float _255 = (min(max(_228, _221.y), 0.0) + length(max(_221, vec2(0.0)))) - _217;
                highp vec2 _401;
                if (uData[10].w > 0.0)
                {
                    highp float _264 = (uData[9].x < 0.0) ? (-1.0) : 1.0;
                    highp float _267 = (uData[9].y < 0.0) ? (-1.0) : 1.0;
                    highp float _287;
                    if (_264 < 0.0)
                    {
                        highp float _279;
                        if (_267 < 0.0)
                        {
                            _279 = _192.x;
                        }
                        else
                        {
                            _279 = _192.w;
                        }
                        _287 = _279;
                    }
                    else
                    {
                        highp float _286;
                        if (_267 < 0.0)
                        {
                            _286 = _192.y;
                        }
                        else
                        {
                            _286 = _192.z;
                        }
                        _287 = _286;
                    }
                    highp vec2 _290 = max(uData[_179 * 1 + 0].zw - vec2(_287), vec2(0.0));
                    highp vec2 _294 = (uData[_179 * 1 + 0].xy + (vec2(_264, _267) * _290)) + (uData[9].xy * _287);
                    highp vec2 _309;
                    if (abs(uData[9].x) < 0.001000000047497451305389404296875)
                    {
                        highp float _302 = _290.x;
                        highp vec2 _308 = _294;
                        _308.x = clamp(vTextureCoord.x, uData[_179 * 1 + 0].x - _302, uData[_179 * 1 + 0].x + _302) + (_287 * uData[9].x);
                        _309 = _308;
                    }
                    else
                    {
                        _309 = _294;
                    }
                    highp vec2 _324;
                    if (abs(uData[9].y) < 0.001000000047497451305389404296875)
                    {
                        highp float _317 = _290.y;
                        highp vec2 _323 = _309;
                        _323.y = clamp(vTextureCoord.y, uData[_179 * 1 + 0].y - _317, uData[_179 * 1 + 0].y + _317) + (_287 * uData[9].y);
                        _324 = _323;
                    }
                    else
                    {
                        _324 = _309;
                    }
                    highp float _327 = max(uData[10].w - max(uData[8].w, 1.0), 0.0);
                    highp vec2 _332 = -uData[9].xy;
                    highp float _333 = _332.x;
                    highp float _335 = (_333 < 0.0) ? (-1.0) : 1.0;
                    highp float _336 = _332.y;
                    highp float _338 = (_336 < 0.0) ? (-1.0) : 1.0;
                    highp float _358;
                    if (_335 < 0.0)
                    {
                        highp float _350;
                        if (_338 < 0.0)
                        {
                            _350 = _192.x;
                        }
                        else
                        {
                            _350 = _192.w;
                        }
                        _358 = _350;
                    }
                    else
                    {
                        highp float _357;
                        if (_338 < 0.0)
                        {
                            _357 = _192.y;
                        }
                        else
                        {
                            _357 = _192.z;
                        }
                        _358 = _357;
                    }
                    highp vec2 _361 = max(uData[_179 * 1 + 0].zw - vec2(_358), vec2(0.0));
                    highp vec2 _365 = (uData[_179 * 1 + 0].xy + (vec2(_335, _338) * _361)) + (_332 * _358);
                    highp vec2 _380;
                    if (abs(_333) < 0.001000000047497451305389404296875)
                    {
                        highp float _373 = _361.x;
                        highp vec2 _379 = _365;
                        _379.x = clamp(vTextureCoord.x, uData[_179 * 1 + 0].x - _373, uData[_179 * 1 + 0].x + _373) + (_358 * _333);
                        _380 = _379;
                    }
                    else
                    {
                        _380 = _365;
                    }
                    highp vec2 _395;
                    if (abs(_336) < 0.001000000047497451305389404296875)
                    {
                        highp float _388 = _361.y;
                        highp vec2 _394 = _380;
                        _394.y = clamp(vTextureCoord.y, uData[_179 * 1 + 0].y - _388, uData[_179 * 1 + 0].y + _388) + (_358 * _336);
                        _395 = _394;
                    }
                    else
                    {
                        _395 = _380;
                    }
                    _401 = vec2(1.0 - smoothstep(_327, uData[10].w, length(vTextureCoord - _324)), 1.0 - smoothstep(_327, uData[10].w, length(vTextureCoord - _395)));
                }
                else
                {
                    _401 = vec2(0.0);
                }
                bool _402 = _255 < _163;
                if (_402)
                {
                    _139 = _157;
                    _142 = _165;
                    _144 = _155;
                    _148 = _159;
                    _158 = uData[_179 * 1 + 0].yw;
                    _162 = _163;
                }
                else
                {
                    bool _407 = _255 < _161;
                    highp vec2 _411;
                    if (_407)
                    {
                        _411 = uData[_179 * 1 + 0].yw;
                    }
                    else
                    {
                        _411 = _138;
                    }
                    bvec2 _413 = bvec2(_407);
                    bvec4 _415 = bvec4(_407);
                    _139 = _411;
                    _142 = _407 ? _190 : _141;
                    _144 = vec2(_413.x ? _401.x : _143.x, _413.y ? _401.y : _143.y);
                    _148 = vec4(_415.x ? uData[_185 * 1 + 0].x : _147.x, _415.y ? uData[_185 * 1 + 0].y : _147.y, _415.z ? uData[_185 * 1 + 0].z : _147.z, _415.w ? uData[_185 * 1 + 0].w : _147.w);
                    _158 = _157;
                    _162 = _407 ? _255 : _161;
                }
                bvec2 _418 = bvec2(_402);
                _156 = vec2(_418.x ? _401.x : _155.x, _418.y ? _401.y : _155.y);
                bvec4 _419 = bvec4(_402);
                _160 = vec4(_419.x ? uData[_185 * 1 + 0].x : _159.x, _419.y ? uData[_185 * 1 + 0].y : _159.y, _419.z ? uData[_185 * 1 + 0].z : _159.z, _419.w ? uData[_185 * 1 + 0].w : _159.w);
                _164 = _402 ? _255 : _163;
                _166 = _402 ? _190 : _165;
                highp vec2 _464;
                highp float _465;
                if (uData[_185 * 1 + 0].w < 0.5)
                {
                    highp float _430 = (vTextureCoord.x - uData[_179 * 1 + 0].x) + uData[_179 * 1 + 0].z;
                    highp float _432 = (uData[_179 * 1 + 0].x + uData[_179 * 1 + 0].z) - vTextureCoord.x;
                    highp float _437 = (vTextureCoord.y - uData[_179 * 1 + 0].y) + uData[_179 * 1 + 0].w;
                    highp float _439 = (uData[_179 * 1 + 0].y + uData[_179 * 1 + 0].w) - vTextureCoord.y;
                    highp float _443 = min(min(_430, _432), min(_437, _439));
                    highp vec4 _448 = exp((vec4(_443) - vec4(_430, _432, _437, _439)) / vec4(uData[1].y));
                    highp float _449 = _448.x;
                    highp float _450 = _448.y;
                    highp float _452 = _448.z;
                    highp float _454 = _448.w;
                    highp float _455 = ((_449 + _450) + _452) + _454;
                    _464 = vec2(_450 - _449, _454 - _452) / vec2(_455);
                    _465 = (uData[1].y * log(_455)) - _443;
                }
                else
                {
                    _464 = _248;
                    _465 = _255;
                }
                bool _466 = _465 < _153;
                if (_466)
                {
                    _146 = _149;
                    _152 = _153;
                }
                else
                {
                    bool _470 = _465 < _151;
                    bvec2 _471 = bvec2(_470);
                    _146 = vec2(_471.x ? _464.x : _145.x, _471.y ? _464.y : _145.y);
                    _152 = _470 ? _465 : _151;
                }
                bvec2 _474 = bvec2(_466);
                _150 = vec2(_474.x ? _464.x : _149.x, _474.y ? _464.y : _149.y);
                _154 = _466 ? _465 : _153;
                _138 = _139;
                _141 = _142;
                _143 = _144;
                _145 = _146;
                _147 = _148;
                _149 = _150;
                _151 = _152;
                _153 = _154;
                _155 = _156;
                _157 = _158;
                _159 = _160;
                _161 = _162;
                _163 = _164;
                _165 = _166;
                _167++;
                continue;
            }
            else
            {
                break;
            }
        }
        bool _480 = uData[58].w > 2.5;
        bool _481 = uData[58].w > 1.5;
        highp float _554;
        highp vec2 _555;
        if (_481)
        {
            highp vec2 _487 = vTextureCoord - uData[56].xy;
            highp vec4 _493 = min(uData[57], vec4(min(uData[56].z, uData[56].w)));
            highp float _494 = _487.x;
            highp float _515;
            if (_494 > 0.0)
            {
                highp float _506;
                if (_487.y > 0.0)
                {
                    _506 = _493.z;
                }
                else
                {
                    _506 = _493.y;
                }
                _515 = _506;
            }
            else
            {
                highp float _514;
                if (_487.y > 0.0)
                {
                    _514 = _493.w;
                }
                else
                {
                    _514 = _493.x;
                }
                _515 = _514;
            }
            highp vec2 _519 = (abs(_487) - uData[56].zw) + vec2(_515);
            highp float _521 = (_494 < 0.0) ? (-1.0) : 1.0;
            highp float _524 = (_487.y < 0.0) ? (-1.0) : 1.0;
            highp float _526 = _519.x;
            bool _532;
            if (_526 > 0.0)
            {
                _532 = _519.y > 0.0;
            }
            else
            {
                _532 = false;
            }
            highp vec2 _546;
            if (_532)
            {
                _546 = normalize(_519) * vec2(_521, _524);
            }
            else
            {
                highp vec2 _545;
                if (_526 > _519.y)
                {
                    _545 = vec2(_521, 0.0);
                }
                else
                {
                    _545 = vec2(0.0, _524);
                }
                _546 = _545;
            }
            _554 = (min(max(_526, _519.y), 0.0) + length(max(_519, vec2(0.0)))) - _515;
            _555 = _546;
        }
        else
        {
            _554 = -1000000000.0;
            _555 = vec2(0.0);
        }
        bool _559;
        if (_481)
        {
            _559 = !_480;
        }
        else
        {
            _559 = false;
        }
        highp vec2 _604;
        highp vec2 _605;
        highp float _606;
        highp vec2 _607;
        highp vec2 _608;
        highp vec2 _609;
        highp vec2 _610;
        highp vec4 _611;
        highp vec4 _612;
        highp float _613;
        highp float _614;
        highp float _615;
        highp float _616;
        if (_559)
        {
            highp float _562 = 1.0 - _554;
            bool _563 = _562 < _163;
            highp vec2 _579;
            highp vec2 _580;
            highp float _581;
            highp vec2 _582;
            highp vec4 _583;
            highp float _584;
            if (_563)
            {
                _579 = _157;
                _580 = uData[56].yw;
                _581 = _165;
                _582 = _155;
                _583 = _159;
                _584 = _163;
            }
            else
            {
                bool _568 = _562 < _161;
                highp vec2 _572;
                if (_568)
                {
                    _572 = uData[56].yw;
                }
                else
                {
                    _572 = _138;
                }
                bvec2 _574 = bvec2(_568);
                bvec4 _576 = bvec4(_568);
                _579 = _572;
                _580 = _157;
                _581 = _568 ? _165 : _141;
                _582 = vec2(_574.x ? vec2(0.0).x : _143.x, _574.y ? vec2(0.0).y : _143.y);
                _583 = vec4(_576.x ? uData[58].x : _147.x, _576.y ? uData[58].y : _147.y, _576.z ? uData[58].z : _147.z, _576.w ? uData[58].w : _147.w);
                _584 = _568 ? _562 : _161;
            }
            bvec2 _585 = bvec2(_563);
            bvec4 _587 = bvec4(_563);
            highp vec2 _590 = -_555;
            bool _591 = _562 < _153;
            highp vec2 _599;
            highp float _600;
            if (_591)
            {
                _599 = _149;
                _600 = _153;
            }
            else
            {
                bool _595 = _562 < _151;
                bvec2 _596 = bvec2(_595);
                _599 = vec2(_596.x ? _590.x : _145.x, _596.y ? _590.y : _145.y);
                _600 = _595 ? _562 : _151;
            }
            bvec2 _601 = bvec2(_591);
            _604 = _579;
            _605 = _580;
            _606 = _581;
            _607 = _582;
            _608 = vec2(_585.x ? vec2(0.0).x : _155.x, _585.y ? vec2(0.0).y : _155.y);
            _609 = _599;
            _610 = vec2(_601.x ? _590.x : _149.x, _601.y ? _590.y : _149.y);
            _611 = _583;
            _612 = vec4(_587.x ? uData[58].x : _159.x, _587.y ? uData[58].y : _159.y, _587.z ? uData[58].z : _159.z, _587.w ? uData[58].w : _159.w);
            _613 = _600;
            _614 = _591 ? _562 : _153;
            _615 = _584;
            _616 = _563 ? _562 : _163;
        }
        else
        {
            _604 = _138;
            _605 = _157;
            _606 = _141;
            _607 = _143;
            _608 = _155;
            _609 = _145;
            _610 = _149;
            _611 = _147;
            _612 = _159;
            _613 = _151;
            _614 = _153;
            _615 = _161;
            _616 = _163;
        }
        highp float _618 = max(uData[1].x, 9.9999997473787516355514526367188e-05);
        highp float _623 = max(_618 - abs(_616 - _615), 0.0) / _618;
        highp float _624 = _623 * _623;
        highp float _625 = _624 * 0.5;
        highp float _630;
        if (_615 < _616)
        {
            _630 = 1.0 - _625;
        }
        else
        {
            _630 = _625;
        }
        highp float _634 = min(_616, _615) - ((_624 * _618) * 0.25);
        highp float _639 = max(_618 - abs(_614 - _613), 0.0) / _618;
        highp float _640 = _639 * _639;
        highp float _641 = _640 * 0.5;
        highp float _646;
        if (_613 < _614)
        {
            _646 = 1.0 - _641;
        }
        else
        {
            _646 = _641;
        }
        highp float _650 = min(_614, _613) - ((_640 * _618) * 0.25);
        highp float _654;
        if (_480)
        {
            _654 = max(_634, _554);
        }
        else
        {
            _654 = _634;
        }
        highp float _657 = clamp(0.5 - max(_654, _554), 0.0, 1.0);
        if (_657 <= 0.0)
        {
            discard;
        }
        if (vColor.x < 0.5)
        {
            _1186 = vec4(0.0, 0.0, 0.0, _657);
            break;
        }
        highp vec4 _668 = mix(_612, _611, vec4(_630));
        highp vec2 _670 = mix(_610, _609, vec2(_646));
        bool _674;
        if (_480)
        {
            _674 = _554 > _650;
        }
        else
        {
            _674 = false;
        }
        bvec2 _676 = bvec2(_674);
        highp vec2 _677 = vec2(_676.x ? _555.x : _670.x, _676.y ? _555.y : _670.y);
        highp vec2 _678 = vec2(_630);
        highp vec2 _682 = mix(_608, _607, _678) * min(length(_677), 1.0);
        highp float _684 = max(0.0, -(_674 ? _554 : _650));
        highp float _685 = -_684;
        highp float _688 = exp(_685 / uData[1].z);
        highp float _694 = _668.y;
        highp float _728;
        highp float _729;
        highp vec2 _730;
        if (_136)
        {
            highp float _702 = max(min(uData[5].y * mix(_165, _606, _630), uData[6].w), 1.0);
            highp float _705 = clamp(1.0 - (_684 / _702), 0.0, 1.0);
            highp float _710 = (((uData[5].z * _702) * _694) * _705) * _705;
            _728 = _705;
            _729 = _710;
            _730 = clamp(((vTextureCoord - (_677 * _710)) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        else
        {
            _728 = 0.0;
            _729 = 0.0;
            _730 = clamp(((vTextureCoord + (_677 * ((uData[2].x * _694) * _688))) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        highp vec4 _734 = textureLod(uSampler, _730, 0.0);
        bool _736 = uData[4].w > 0.5;
        highp vec4 _744;
        if (_736)
        {
            _744 = textureLod(uTex1, _730, 0.0);
        }
        else
        {
            _744 = _734;
        }
        bool _749;
        if (_136)
        {
            _749 = uData[6].y > 0.0;
        }
        else
        {
            _749 = false;
        }
        bool _753;
        if (_749)
        {
            _753 = _729 > 0.5;
        }
        else
        {
            _753 = false;
        }
        highp vec4 _814;
        highp vec4 _815;
        if (_753)
        {
            highp vec2 _761 = (_677 * ((_729 * 0.039999999105930328369140625) * uData[6].y)) * uData[0].zw;
            highp vec2 _763 = clamp(_730 + _761, vec2(0.0), vec2(1.0));
            highp vec2 _765 = clamp(_730 - _761, vec2(0.0), vec2(1.0));
            highp vec4 _769 = textureLod(uSampler, _763, 0.0);
            highp float _774 = _734.w;
            highp float _775 = (_769.x / max(_769.w, 9.9999997473787516355514526367188e-05)) * _774;
            highp vec4 _776 = _734;
            _776.x = _775;
            highp vec4 _780 = textureLod(uSampler, _765, 0.0);
            highp float _785 = (_780.z / max(_780.w, 9.9999997473787516355514526367188e-05)) * _774;
            _776.z = _785;
            highp vec4 _813;
            if (_736)
            {
                highp vec4 _793 = textureLod(uTex1, _763, 0.0);
                highp vec4 _800 = _744;
                _800.x = (_793.x / max(_793.w, 9.9999997473787516355514526367188e-05)) * _744.w;
                highp vec4 _804 = textureLod(uTex1, _765, 0.0);
                _800.z = (_804.z / max(_804.w, 9.9999997473787516355514526367188e-05)) * _744.w;
                _813 = _800;
            }
            else
            {
                highp vec4 _811 = _744;
                _811.x = _775;
                _811.z = _785;
                _813 = _811;
            }
            _814 = _813;
            _815 = _776;
        }
        else
        {
            _814 = _744;
            _815 = _734;
        }
        bool _817 = uData[4].x > 1.5;
        highp float _831;
        if (_817)
        {
            _831 = uData[3].w;
        }
        else
        {
            highp float _830;
            if ((uData[6].x - 2.0 * trunc(uData[6].x / 2.0)) > 0.5)
            {
                _830 = 1.0;
            }
            else
            {
                _830 = _815.w;
            }
            _831 = _830;
        }
        highp vec4 _840 = vec4(_815.xyz / vec3(max(_815.w, 9.9999997473787516355514526367188e-05)), 1.0);
        highp vec4 _849 = vec4(_814.xyz / vec3(max(_814.w, 9.9999997473787516355514526367188e-05)), 1.0);
        highp float _856;
        if (_817)
        {
            _856 = 1.0;
        }
        else
        {
            _856 = (uData[4].z > 0.5) ? uData[4].x : 0.0;
        }
        bool _860;
        if (_136)
        {
            _860 = !_817;
        }
        else
        {
            _860 = false;
        }
        highp float _869;
        if (_860)
        {
            _869 = _856 * (1.0 - ((_728 * _728) * (1.0 - smoothstep(0.800000011920928955078125, 1.0, _856))));
        }
        else
        {
            _869 = _856;
        }
        highp float _872 = 1.0 - _869;
        highp float _880;
        if (_136)
        {
            _880 = _728;
        }
        else
        {
            _880 = _688 * _688;
        }
        highp float _883 = clamp(((uData[2].y * _694) * _880) * _872, 0.0, 1.0);
        highp vec4 _889 = ((_849 * _883) + ((mix(_849, _840, vec4(clamp(_668.x, 0.0, 1.0))) * _872) * (1.0 - _883))) + (uData[3] * _869);
        highp vec4 _932;
        if (_817)
        {
            _932 = vec4(uData[3].xyz / vec3(max(uData[3].w, 9.9999997473787516355514526367188e-05)), 1.0);
        }
        else
        {
            highp vec4 _905 = _889 + (_840 * (1.0 - _889.w));
            highp vec4 _931;
            if (uData[7].w < 1.0)
            {
                highp vec3 _910 = _905.xyz;
                highp float _911 = dot(_910, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875));
                highp float _912 = 0.60000002384185791015625 * uData[7].w;
                highp float _914 = max(uData[7].w - _912, 9.9999997473787516355514526367188e-05);
                highp float _926;
                if (_911 <= _912)
                {
                    _926 = _911;
                }
                else
                {
                    _926 = _912 + (_914 * (1.0 - exp((-(_911 - _912)) / _914)));
                }
                highp vec3 _929 = _910 * (_926 / max(_911, 9.9999997473787516355514526367188e-05));
                _931 = vec4(_929.x, _929.y, _929.z, _905.w);
            }
            else
            {
                _931 = _905;
            }
            _932 = _931;
        }
        highp float _935 = dot(_677, uData[9].xy);
        highp float _936 = max(_935, 0.0);
        highp float _938 = max(-_935, 0.0);
        highp float _941 = abs(_935);
        bool _945;
        if (_136)
        {
            _945 = uData[6].z > 0.0;
        }
        else
        {
            _945 = false;
        }
        bool _947 = uData[10].x > 0.0;
        highp float _971;
        if (_947)
        {
            _971 = 0.0;
        }
        else
        {
            highp float _970;
            if (_945)
            {
                _970 = (uData[6].z * (1.0 - smoothstep(0.20000000298023223876953125, 0.699999988079071044921875, _941))) * exp((-max(0.0, -_654)) / (uData[2].z * 2.5));
            }
            else
            {
                _970 = uData[8].x * (1.0 - smoothstep(0.0, uData[2].z * 0.625, -_654));
            }
            _971 = _970;
        }
        highp float _981;
        if (_136)
        {
            _981 = max((uData[5].w * _728) * _728, _971) * min(_694, 1.0);
        }
        else
        {
            _981 = 0.0;
        }
        highp float _984 = _831 * (1.0 - _981);
        highp vec4 _990 = vec4(_932.xyz * _984, _984 + _981);
        highp float _1012;
        if (_136)
        {
            highp float _1003;
            if (_945)
            {
                _1003 = uData[6].z * max(smoothstep(0.75, 1.0, _941), max(_682.x, _682.y));
            }
            else
            {
                _1003 = 0.25;
            }
            _1012 = _1003;
        }
        else
        {
            _1012 = (0.449999988079071044921875 * ((_936 * sqrt(_936)) + ((0.75 * _938) * sqrt(_938)))) + 0.0599999986588954925537109375;
        }
        highp float _1039;
        if (_945)
        {
            _1039 = exp((-max(0.0, -_654)) / (uData[2].z * 1.25));
        }
        else
        {
            highp float _1038;
            if (_136)
            {
                highp float _1026 = -_654;
                _1038 = smoothstep(uData[2].z * 0.3125, uData[2].z * 0.625, _1026) * (1.0 - smoothstep(uData[2].z * 1.5, uData[2].z * 2.0, _1026));
            }
            else
            {
                _1038 = exp((-max(0.0, -_654)) / uData[2].z);
            }
            _1039 = _1038;
        }
        highp float _1051;
        if (_947)
        {
            _1051 = 0.0;
        }
        else
        {
            highp float _1049;
            if (_136)
            {
                _1049 = 0.0;
            }
            else
            {
                _1049 = (0.039999999105930328369140625 * exp(_685 / uData[1].w)) * _936;
            }
            _1051 = (_1039 * _1012) + _1049;
        }
        highp vec2 _1052 = mix(_605, _604, _678);
        highp float _1056 = _1052.y;
        highp float _1062 = clamp((vTextureCoord.y - (_1052.x - _1056)) / max(2.0 * _1056, 9.9999997473787516355514526367188e-05), 0.0, 1.0);
        highp float _1080;
        if (uData[4].z > 0.5)
        {
            _1080 = uData[4].y + ((uData[7].x + ((uData[7].y - uData[7].x) * _1062)) + (uData[7].z * (1.0 - smoothstep(0.0, 0.37999999523162841796875, _1062))));
        }
        else
        {
            _1080 = 0.0;
        }
        highp vec3 _1090 = _990.xyz + vec3(clamp((_1080 + _668.z) + ((_694 * uData[2].w) * _1051), 0.0, 1.0));
        highp vec4 _1162;
        if (_947)
        {
            highp vec2 _1100;
            if (dot(_677, _677) > 9.9999999392252902907785028219223e-09)
            {
                _1100 = normalize(_677);
            }
            else
            {
                _1100 = vec2(0.0);
            }
            highp float _1101 = dot(_1100, uData[9].xy);
            highp float _1103 = mix(8.0, 1.0, uData[9].z);
            highp float _1111 = pow(max(_1101, 0.0), _1103) + (uData[9].w * pow(max(-_1101, 0.0), _1103));
            highp float _1112 = min(_694, 1.0);
            highp float _1119 = -_654;
            highp float _1121 = smoothstep(-0.5, 0.5, _1119);
            highp float _1123 = -max(0.0, _1119);
            highp vec3 _1160 = (_1090.xyz * (1.0 - (((uData[10].z * (1.0 - abs(_1101))) * (_1121 * exp(_1123 / max(uData[2].z * 2.5, 0.001000000047497451305389404296875)))) * _1112))) + vec3(_1112 * (((uData[10].x * max(_1111, max(_682.x, uData[9].w * _682.y))) * (_1121 * exp(_1123 / max(uData[8].y, 0.001000000047497451305389404296875)))) + ((uData[10].y * _1111) * (smoothstep(uData[8].y - 0.5, uData[8].y + 0.5, _1119) * exp((-max(0.0, _1119 - uData[8].y)) / max(uData[8].z, 0.001000000047497451305389404296875))))));
            _1162 = vec4(_1160.x, _1160.y, _1160.z, _990.w);
        }
        else
        {
            _1162 = vec4(_1090.x, _1090.y, _1090.z, _990.w);
        }
        highp vec4 _1163 = clamp(_1162, vec4(0.0), vec4(1.0));
        highp float _1170 = max(_1163.w, max(_1163.x, max(_1163.y, _1163.z)));
        highp vec4 _1171 = _1163;
        _1171.w = _1170;
        highp vec3 _1182 = _1171.xyz + vec3(((fract(52.98291778564453125 * fract(dot(vTextureCoord, vec2(0.067110560834407806396484375, 0.005837149918079376220703125)))) - 0.5) * uData[5].x) * _1170);
        _1186 = clamp(vec4(_1182.x, _1182.y, _1182.z, _1171.w), vec4(0.0), vec4(1.0)) * _657;
        break;
    } while(false);
    out_var_SV_Target0 = _1186;
}

