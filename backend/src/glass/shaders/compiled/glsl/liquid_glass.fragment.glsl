#version 300 es
precision highp float;
precision highp int;

uniform highp vec4 uData[60];
uniform highp sampler2D uSampler;
uniform highp sampler2D uTex1;

in highp vec4 vColor;
in highp vec2 vTextureCoord;
layout(location = 0) out highp vec4 out_var_SV_Target0;

void main()
{
    highp vec4 _2027;
    do
    {
        int _115 = int((vColor.y * 255.0) + 0.5);
        int _120 = int((vColor.z * 255.0) + 0.5);
        bool _146 = uData[5].y > 0.0;
        highp vec4 _148;
        highp vec4 _151;
        highp vec2 _153;
        highp float _155;
        highp vec2 _157;
        highp vec2 _159;
        highp vec2 _161;
        highp float _163;
        highp float _165;
        highp vec2 _167;
        highp vec2 _169;
        highp float _171;
        highp float _173;
        highp float _175;
        _148 = vec4(0.0);
        _151 = vec4(0.0);
        _153 = vec2(0.0, 1.0);
        _155 = 1000000000.0;
        _157 = vec2(0.0);
        _159 = vec2(0.0);
        _161 = vec2(0.0);
        _163 = 1000000000.0;
        _165 = 1000000000.0;
        _167 = vec2(0.0);
        _169 = vec2(0.0, 1.0);
        _171 = 1000000000.0;
        _173 = 1000000000.0;
        _175 = 1000000000.0;
        highp vec4 _152;
        highp vec2 _162;
        highp float _166;
        highp vec2 _168;
        highp float _174;
        highp float _176;
        int _181;
        highp vec4 _149;
        highp vec2 _154;
        highp float _156;
        highp vec2 _158;
        highp vec2 _160;
        highp float _164;
        highp vec2 _170;
        highp float _172;
        int _177 = _115;
        for (;;)
        {
            _181 = _115 + _120;
            bool _186;
            if (_177 < _181)
            {
                _186 = _177 < 16;
            }
            else
            {
                _186 = false;
            }
            if (_186)
            {
                int _188 = 3 * _177;
                int _195 = _188 + 14;
                bool _203;
                if (uData[_195 * 1 + 0].w >= (-0.5))
                {
                    _203 = uData[_195 * 1 + 0].w > 3.5;
                }
                else
                {
                    _203 = true;
                }
                highp vec4 _213;
                highp vec4 _214;
                highp vec4 _215;
                if (_203)
                {
                    highp vec4 _211 = uData[59];
                    _211.z = 0.0;
                    _213 = _211;
                    _214 = uData[57];
                    _215 = uData[58];
                }
                else
                {
                    _213 = uData[_195 * 1 + 0];
                    _214 = uData[(12 + _188) * 1 + 0];
                    _215 = uData[(_188 + 13) * 1 + 0];
                }
                highp float _218 = min(_214.z, _214.w);
                highp vec4 _220 = min(_215, vec4(_218));
                highp vec2 _505;
                highp float _506;
                if (_203)
                {
                    highp vec4 _295 = min(uData[58], vec4(min(uData[57].z, uData[57].w)));
                    int _298 = int(uData[59].z);
                    highp vec2 _300 = vTextureCoord - uData[57].xy;
                    highp float _302 = _300.x;
                    highp float _323;
                    if (_302 > 0.0)
                    {
                        highp float _322;
                        if (_300.y > 0.0)
                        {
                            _322 = _295.z;
                        }
                        else
                        {
                            _322 = _295.y;
                        }
                        _323 = _322;
                    }
                    else
                    {
                        highp float _314;
                        if (_300.y > 0.0)
                        {
                            _314 = _295.w;
                        }
                        else
                        {
                            _314 = _295.x;
                        }
                        _323 = _314;
                    }
                    highp vec2 _327 = (abs(_300) - uData[57].zw) + vec2(_323);
                    highp float _329 = (_302 < 0.0) ? (-1.0) : 1.0;
                    highp float _332 = (_300.y < 0.0) ? (-1.0) : 1.0;
                    highp float _334 = _327.x;
                    bool _340;
                    if (_334 > 0.0)
                    {
                        _340 = _327.y > 0.0;
                    }
                    else
                    {
                        _340 = false;
                    }
                    highp vec2 _354;
                    if (_340)
                    {
                        _354 = normalize(_327) * vec2(_329, _332);
                    }
                    else
                    {
                        highp vec2 _351;
                        if (_334 > _327.y)
                        {
                            _351 = vec2(_329, 0.0);
                        }
                        else
                        {
                            _351 = vec2(0.0, _332);
                        }
                        _354 = _351;
                    }
                    highp vec2 _363;
                    highp float _366;
                    _363 = _354;
                    _366 = (min(max(_334, _327.y), 0.0) + length(max(_327, vec2(0.0)))) - _323;
                    highp vec2 _364;
                    highp float _367;
                    int _368 = 0;
                    for (;;)
                    {
                        bool _376;
                        if (_368 < _298)
                        {
                            _376 = _368 < 4;
                        }
                        else
                        {
                            _376 = false;
                        }
                        if (_376)
                        {
                            int _378 = 14 - _368;
                            int _379 = 3 * _378;
                            int _380 = 12 + _379;
                            int _383 = _379 + 13;
                            if (uData[_383 * 1 + 0].x == 0.0)
                            {
                                _364 = _363;
                                _367 = _366;
                                int _369 = _368 + 1;
                                _363 = _364;
                                _366 = _367;
                                _368 = _369;
                                continue;
                            }
                            highp float _392 = clamp(uData[_383 * 1 + 0].x / uData[_383 * 1 + 0].y, 0.0, 1.0);
                            bool _394 = uData[_380 * 1 + 0].x < 0.5;
                            highp float _402;
                            if (_394)
                            {
                                _402 = vTextureCoord.y;
                            }
                            else
                            {
                                _402 = vTextureCoord.x;
                            }
                            highp float _410;
                            if (_394)
                            {
                                _410 = vTextureCoord.x;
                            }
                            else
                            {
                                _410 = vTextureCoord.y;
                            }
                            highp float _412 = _410 - uData[_380 * 1 + 0].y;
                            highp float _413 = uData[_383 * 1 + 0].x * 0.5;
                            highp float _416 = uData[_380 * 1 + 0].w - uData[_380 * 1 + 0].z;
                            highp float _417 = smoothstep(0.0, 0.60000002384185791015625, _392);
                            highp float _446;
                            highp float _447;
                            if (uData[_383 * 1 + 0].w > 2.5)
                            {
                                highp float _437 = _402 - ((uData[_380 * 1 + 0].z + uData[_380 * 1 + 0].w) * 0.5);
                                _446 = (_437 < 0.0) ? 1.0 : (-1.0);
                                _447 = max(((_416 * 0.5) * (1.0 - _417)) - abs(_437), 0.0);
                            }
                            else
                            {
                                bool _423 = uData[_383 * 1 + 0].w < 1.5;
                                highp float _429;
                                if (_423)
                                {
                                    _429 = _402 - uData[_380 * 1 + 0].z;
                                }
                                else
                                {
                                    _429 = uData[_380 * 1 + 0].w - _402;
                                }
                                _446 = _423 ? 1.0 : (-1.0);
                                _447 = max(_429 - ((_416 - _413) * _417), 0.0);
                            }
                            highp float _449 = length(vec2(_412, _447));
                            highp float _450 = _449 - _413;
                            highp vec2 _465;
                            if (_449 > 0.0)
                            {
                                highp vec2 _459 = vec2(-_412, (-_447) * _446) / vec2(_449);
                                highp vec2 _464;
                                if (uData[_380 * 1 + 0].x > 0.5)
                                {
                                    _464 = _459.yx;
                                }
                                else
                                {
                                    _464 = _459;
                                }
                                _465 = _464;
                            }
                            else
                            {
                                _465 = vec2(0.0);
                            }
                            highp float _467 = uData[_383 * 1 + 0].z * _392;
                            highp vec2 _471 = max(vec2(_467 + _366, _467 - _450), vec2(0.0));
                            highp float _472 = length(_471);
                            bool _477;
                            if (_467 > 0.0)
                            {
                                _477 = _472 > 0.0;
                            }
                            else
                            {
                                _477 = false;
                            }
                            highp vec2 _492;
                            if (_477)
                            {
                                _492 = ((_363 * _471.x) + (_465 * _471.y)) / vec2(_472);
                            }
                            else
                            {
                                bvec2 _483 = bvec2((-_450) > _366);
                                _492 = vec2(_483.x ? _465.x : _363.x, _483.y ? _465.y : _363.y);
                            }
                            highp float _493 = -_450;
                            highp float _504;
                            do
                            {
                                if (_467 == 0.0)
                                {
                                    _504 = max(_366, _493);
                                    break;
                                }
                                _504 = min(-_467, max(_366, _493)) + _472;
                                break;
                            } while(false);
                            _364 = _492;
                            _367 = _504;
                            int _369 = _368 + 1;
                            _363 = _364;
                            _366 = _367;
                            _368 = _369;
                            continue;
                        }
                        else
                        {
                            break;
                        }
                    }
                    _505 = _363;
                    _506 = _366;
                }
                else
                {
                    highp vec2 _225 = vTextureCoord - _214.xy;
                    highp float _227 = _225.x;
                    highp float _248;
                    if (_227 > 0.0)
                    {
                        highp float _247;
                        if (_225.y > 0.0)
                        {
                            _247 = _220.z;
                        }
                        else
                        {
                            _247 = _220.y;
                        }
                        _248 = _247;
                    }
                    else
                    {
                        highp float _239;
                        if (_225.y > 0.0)
                        {
                            _239 = _220.w;
                        }
                        else
                        {
                            _239 = _220.x;
                        }
                        _248 = _239;
                    }
                    highp vec2 _252 = (abs(_225) - _214.zw) + vec2(_248);
                    highp float _254 = (_227 < 0.0) ? (-1.0) : 1.0;
                    highp float _257 = (_225.y < 0.0) ? (-1.0) : 1.0;
                    highp float _259 = _252.x;
                    bool _265;
                    if (_259 > 0.0)
                    {
                        _265 = _252.y > 0.0;
                    }
                    else
                    {
                        _265 = false;
                    }
                    highp vec2 _279;
                    if (_265)
                    {
                        _279 = normalize(_252) * vec2(_254, _257);
                    }
                    else
                    {
                        highp vec2 _276;
                        if (_259 > _252.y)
                        {
                            _276 = vec2(_254, 0.0);
                        }
                        else
                        {
                            _276 = vec2(0.0, _257);
                        }
                        _279 = _276;
                    }
                    _505 = _279;
                    _506 = (min(max(_259, _252.y), 0.0) + length(max(_252, vec2(0.0)))) - _248;
                }
                highp vec2 _654;
                if (uData[10].w > 0.0)
                {
                    highp float _515 = (uData[9].x < 0.0) ? (-1.0) : 1.0;
                    highp float _518 = (uData[9].y < 0.0) ? (-1.0) : 1.0;
                    highp float _538;
                    if (_515 < 0.0)
                    {
                        highp float _537;
                        if (_518 < 0.0)
                        {
                            _537 = _220.x;
                        }
                        else
                        {
                            _537 = _220.w;
                        }
                        _538 = _537;
                    }
                    else
                    {
                        highp float _530;
                        if (_518 < 0.0)
                        {
                            _530 = _220.y;
                        }
                        else
                        {
                            _530 = _220.z;
                        }
                        _538 = _530;
                    }
                    highp vec2 _542 = max(_214.zw - vec2(_538), vec2(0.0));
                    highp vec2 _547 = (_214.xy + (vec2(_515, _518) * _542)) + (uData[9].xy * _538);
                    highp vec2 _562;
                    if (abs(uData[9].x) < 0.001000000047497451305389404296875)
                    {
                        highp float _555 = _542.x;
                        highp vec2 _561 = _547;
                        _561.x = clamp(vTextureCoord.x, _214.x - _555, _214.x + _555) + (_538 * uData[9].x);
                        _562 = _561;
                    }
                    else
                    {
                        _562 = _547;
                    }
                    highp vec2 _577;
                    if (abs(uData[9].y) < 0.001000000047497451305389404296875)
                    {
                        highp float _570 = _542.y;
                        highp vec2 _576 = _562;
                        _576.y = clamp(vTextureCoord.y, _214.y - _570, _214.y + _570) + (_538 * uData[9].y);
                        _577 = _576;
                    }
                    else
                    {
                        _577 = _562;
                    }
                    highp float _580 = max(uData[10].w - max(uData[8].w, 1.0), 0.0);
                    highp vec2 _585 = -uData[9].xy;
                    highp float _586 = _585.x;
                    highp float _588 = (_586 < 0.0) ? (-1.0) : 1.0;
                    highp float _589 = _585.y;
                    highp float _591 = (_589 < 0.0) ? (-1.0) : 1.0;
                    highp float _611;
                    if (_588 < 0.0)
                    {
                        highp float _610;
                        if (_591 < 0.0)
                        {
                            _610 = _220.x;
                        }
                        else
                        {
                            _610 = _220.w;
                        }
                        _611 = _610;
                    }
                    else
                    {
                        highp float _603;
                        if (_591 < 0.0)
                        {
                            _603 = _220.y;
                        }
                        else
                        {
                            _603 = _220.z;
                        }
                        _611 = _603;
                    }
                    highp vec2 _614 = max(_214.zw - vec2(_611), vec2(0.0));
                    highp vec2 _618 = (_214.xy + (vec2(_588, _591) * _614)) + (_585 * _611);
                    highp vec2 _633;
                    if (abs(_586) < 0.001000000047497451305389404296875)
                    {
                        highp float _626 = _614.x;
                        highp vec2 _632 = _618;
                        _632.x = clamp(vTextureCoord.x, _214.x - _626, _214.x + _626) + (_611 * _586);
                        _633 = _632;
                    }
                    else
                    {
                        _633 = _618;
                    }
                    highp vec2 _648;
                    if (abs(_589) < 0.001000000047497451305389404296875)
                    {
                        highp float _641 = _614.y;
                        highp vec2 _647 = _633;
                        _647.y = clamp(vTextureCoord.y, _214.y - _641, _214.y + _641) + (_611 * _589);
                        _648 = _647;
                    }
                    else
                    {
                        _648 = _633;
                    }
                    _654 = vec2(1.0 - smoothstep(_580, uData[10].w, length(vTextureCoord - _577)), 1.0 - smoothstep(_580, uData[10].w, length(vTextureCoord - _648)));
                }
                else
                {
                    _654 = vec2(0.0);
                }
                bool _655 = _506 < _173;
                if (_655)
                {
                    _149 = _151;
                    _154 = _169;
                    _156 = _175;
                    _158 = _167;
                    _170 = _214.yw;
                    _172 = _173;
                }
                else
                {
                    bool _659 = _506 < _171;
                    highp vec2 _663;
                    if (_659)
                    {
                        _663 = _214.yw;
                    }
                    else
                    {
                        _663 = _153;
                    }
                    bvec4 _664 = bvec4(_659);
                    bvec2 _667 = bvec2(_659);
                    _149 = vec4(_664.x ? _213.x : _148.x, _664.y ? _213.y : _148.y, _664.z ? _213.z : _148.z, _664.w ? _213.w : _148.w);
                    _154 = _663;
                    _156 = _659 ? _218 : _155;
                    _158 = vec2(_667.x ? _654.x : _157.x, _667.y ? _654.y : _157.y);
                    _170 = _169;
                    _172 = _659 ? _506 : _171;
                }
                bvec4 _671 = bvec4(_655);
                _152 = vec4(_671.x ? _213.x : _151.x, _671.y ? _213.y : _151.y, _671.z ? _213.z : _151.z, _671.w ? _213.w : _151.w);
                bvec2 _672 = bvec2(_655);
                _168 = vec2(_672.x ? _654.x : _167.x, _672.y ? _654.y : _167.y);
                _174 = _655 ? _506 : _173;
                _176 = _655 ? _218 : _175;
                highp vec2 _995;
                highp float _996;
                if (_203)
                {
                    highp float _732 = uData[1].y * clamp(_218 / (3.0 * uData[1].z), 9.9999997473787516355514526367188e-05, 1.0);
                    highp vec4 _741 = min(uData[58], vec4(min(uData[57].z, uData[57].w)));
                    int _744 = int(uData[59].z);
                    highp vec2 _850;
                    highp float _851;
                    if (_732 > 0.0)
                    {
                        highp float _816 = (vTextureCoord.x - uData[57].x) + uData[57].z;
                        highp float _818 = (uData[57].x + uData[57].z) - vTextureCoord.x;
                        highp float _823 = (vTextureCoord.y - uData[57].y) + uData[57].w;
                        highp float _825 = (uData[57].y + uData[57].w) - vTextureCoord.y;
                        highp float _829 = min(min(_816, _818), min(_823, _825));
                        highp vec4 _834 = exp((vec4(_829) - vec4(_816, _818, _823, _825)) / vec4(_732));
                        highp float _835 = _834.x;
                        highp float _836 = _834.y;
                        highp float _838 = _834.z;
                        highp float _840 = _834.w;
                        highp float _841 = ((_835 + _836) + _838) + _840;
                        _850 = vec2(_836 - _835, _840 - _838) / vec2(_841);
                        _851 = (_732 * log(_841)) - _829;
                    }
                    else
                    {
                        highp vec2 _750 = vTextureCoord - uData[57].xy;
                        highp float _752 = _750.x;
                        highp float _773;
                        if (_752 > 0.0)
                        {
                            highp float _772;
                            if (_750.y > 0.0)
                            {
                                _772 = _741.z;
                            }
                            else
                            {
                                _772 = _741.y;
                            }
                            _773 = _772;
                        }
                        else
                        {
                            highp float _764;
                            if (_750.y > 0.0)
                            {
                                _764 = _741.w;
                            }
                            else
                            {
                                _764 = _741.x;
                            }
                            _773 = _764;
                        }
                        highp vec2 _777 = (abs(_750) - uData[57].zw) + vec2(_773);
                        highp float _779 = (_752 < 0.0) ? (-1.0) : 1.0;
                        highp float _782 = (_750.y < 0.0) ? (-1.0) : 1.0;
                        highp float _784 = _777.x;
                        bool _790;
                        if (_784 > 0.0)
                        {
                            _790 = _777.y > 0.0;
                        }
                        else
                        {
                            _790 = false;
                        }
                        highp vec2 _804;
                        if (_790)
                        {
                            _804 = normalize(_777) * vec2(_779, _782);
                        }
                        else
                        {
                            highp vec2 _801;
                            if (_784 > _777.y)
                            {
                                _801 = vec2(_779, 0.0);
                            }
                            else
                            {
                                _801 = vec2(0.0, _782);
                            }
                            _804 = _801;
                        }
                        _850 = _804;
                        _851 = (min(max(_784, _777.y), 0.0) + length(max(_777, vec2(0.0)))) - _773;
                    }
                    highp vec2 _853;
                    highp float _856;
                    _853 = _850;
                    _856 = _851;
                    highp vec2 _854;
                    highp float _857;
                    int _858 = 0;
                    for (;;)
                    {
                        bool _866;
                        if (_858 < _744)
                        {
                            _866 = _858 < 4;
                        }
                        else
                        {
                            _866 = false;
                        }
                        if (_866)
                        {
                            int _868 = 14 - _858;
                            int _869 = 3 * _868;
                            int _870 = 12 + _869;
                            int _873 = _869 + 13;
                            if (uData[_873 * 1 + 0].x == 0.0)
                            {
                                _854 = _853;
                                _857 = _856;
                                int _859 = _858 + 1;
                                _853 = _854;
                                _856 = _857;
                                _858 = _859;
                                continue;
                            }
                            highp float _882 = clamp(uData[_873 * 1 + 0].x / uData[_873 * 1 + 0].y, 0.0, 1.0);
                            bool _884 = uData[_870 * 1 + 0].x < 0.5;
                            highp float _892;
                            if (_884)
                            {
                                _892 = vTextureCoord.y;
                            }
                            else
                            {
                                _892 = vTextureCoord.x;
                            }
                            highp float _900;
                            if (_884)
                            {
                                _900 = vTextureCoord.x;
                            }
                            else
                            {
                                _900 = vTextureCoord.y;
                            }
                            highp float _902 = _900 - uData[_870 * 1 + 0].y;
                            highp float _903 = uData[_873 * 1 + 0].x * 0.5;
                            highp float _906 = uData[_870 * 1 + 0].w - uData[_870 * 1 + 0].z;
                            highp float _907 = smoothstep(0.0, 0.60000002384185791015625, _882);
                            highp float _936;
                            highp float _937;
                            if (uData[_873 * 1 + 0].w > 2.5)
                            {
                                highp float _927 = _892 - ((uData[_870 * 1 + 0].z + uData[_870 * 1 + 0].w) * 0.5);
                                _936 = (_927 < 0.0) ? 1.0 : (-1.0);
                                _937 = max(((_906 * 0.5) * (1.0 - _907)) - abs(_927), 0.0);
                            }
                            else
                            {
                                bool _913 = uData[_873 * 1 + 0].w < 1.5;
                                highp float _919;
                                if (_913)
                                {
                                    _919 = _892 - uData[_870 * 1 + 0].z;
                                }
                                else
                                {
                                    _919 = uData[_870 * 1 + 0].w - _892;
                                }
                                _936 = _913 ? 1.0 : (-1.0);
                                _937 = max(_919 - ((_906 - _903) * _907), 0.0);
                            }
                            highp float _939 = length(vec2(_902, _937));
                            highp float _940 = _939 - _903;
                            highp vec2 _955;
                            if (_939 > 0.0)
                            {
                                highp vec2 _949 = vec2(-_902, (-_937) * _936) / vec2(_939);
                                highp vec2 _954;
                                if (uData[_870 * 1 + 0].x > 0.5)
                                {
                                    _954 = _949.yx;
                                }
                                else
                                {
                                    _954 = _949;
                                }
                                _955 = _954;
                            }
                            else
                            {
                                _955 = vec2(0.0);
                            }
                            highp float _957 = uData[_873 * 1 + 0].z * _882;
                            highp vec2 _961 = max(vec2(_957 + _856, _957 - _940), vec2(0.0));
                            highp float _962 = length(_961);
                            bool _967;
                            if (_957 > 0.0)
                            {
                                _967 = _962 > 0.0;
                            }
                            else
                            {
                                _967 = false;
                            }
                            highp vec2 _982;
                            if (_967)
                            {
                                _982 = ((_853 * _961.x) + (_955 * _961.y)) / vec2(_962);
                            }
                            else
                            {
                                bvec2 _973 = bvec2((-_940) > _856);
                                _982 = vec2(_973.x ? _955.x : _853.x, _973.y ? _955.y : _853.y);
                            }
                            highp float _983 = -_940;
                            highp float _994;
                            do
                            {
                                if (_957 == 0.0)
                                {
                                    _994 = max(_856, _983);
                                    break;
                                }
                                _994 = min(-_957, max(_856, _983)) + _962;
                                break;
                            } while(false);
                            _854 = _982;
                            _857 = _994;
                            int _859 = _858 + 1;
                            _853 = _854;
                            _856 = _857;
                            _858 = _859;
                            continue;
                        }
                        else
                        {
                            break;
                        }
                    }
                    _995 = _853;
                    _996 = _856;
                }
                else
                {
                    highp vec2 _725;
                    highp float _726;
                    if (_213.w < 0.5)
                    {
                        highp float _686 = uData[1].y * clamp(_218 / (3.0 * uData[1].z), 9.9999997473787516355514526367188e-05, 1.0);
                        highp float _691 = (vTextureCoord.x - _214.x) + _214.z;
                        highp float _693 = (_214.x + _214.z) - vTextureCoord.x;
                        highp float _698 = (vTextureCoord.y - _214.y) + _214.w;
                        highp float _700 = (_214.y + _214.w) - vTextureCoord.y;
                        highp float _704 = min(min(_691, _693), min(_698, _700));
                        highp vec4 _709 = exp((vec4(_704) - vec4(_691, _693, _698, _700)) / vec4(_686));
                        highp float _710 = _709.x;
                        highp float _711 = _709.y;
                        highp float _713 = _709.z;
                        highp float _715 = _709.w;
                        highp float _716 = ((_710 + _711) + _713) + _715;
                        _725 = vec2(_711 - _710, _715 - _713) / vec2(_716);
                        _726 = (_686 * log(_716)) - _704;
                    }
                    else
                    {
                        _725 = _505;
                        _726 = _506;
                    }
                    _995 = _725;
                    _996 = _726;
                }
                bool _997 = _996 < _165;
                if (_997)
                {
                    _160 = _161;
                    _164 = _165;
                }
                else
                {
                    bool _1001 = _996 < _163;
                    bvec2 _1002 = bvec2(_1001);
                    _160 = vec2(_1002.x ? _995.x : _159.x, _1002.y ? _995.y : _159.y);
                    _164 = _1001 ? _996 : _163;
                }
                bvec2 _1005 = bvec2(_997);
                _162 = vec2(_1005.x ? _995.x : _161.x, _1005.y ? _995.y : _161.y);
                _166 = _997 ? _996 : _165;
                _148 = _149;
                _151 = _152;
                _153 = _154;
                _155 = _156;
                _157 = _158;
                _159 = _160;
                _161 = _162;
                _163 = _164;
                _165 = _166;
                _167 = _168;
                _169 = _170;
                _171 = _172;
                _173 = _174;
                _175 = _176;
                _177++;
                continue;
            }
            else
            {
                break;
            }
        }
        bool _1015;
        if (uData[59].w > 2.5)
        {
            _1015 = uData[59].w < 3.5;
        }
        else
        {
            _1015 = false;
        }
        bool _1016 = uData[59].w > 1.5;
        bool _1020;
        if (_1016)
        {
            _1020 = uData[59].w < 3.5;
        }
        else
        {
            _1020 = false;
        }
        highp float _1093;
        highp vec2 _1094;
        if (_1020)
        {
            highp vec2 _1026 = vTextureCoord - uData[57].xy;
            highp vec4 _1032 = min(uData[58], vec4(min(uData[57].z, uData[57].w)));
            highp float _1033 = _1026.x;
            highp float _1054;
            if (_1033 > 0.0)
            {
                highp float _1053;
                if (_1026.y > 0.0)
                {
                    _1053 = _1032.z;
                }
                else
                {
                    _1053 = _1032.y;
                }
                _1054 = _1053;
            }
            else
            {
                highp float _1045;
                if (_1026.y > 0.0)
                {
                    _1045 = _1032.w;
                }
                else
                {
                    _1045 = _1032.x;
                }
                _1054 = _1045;
            }
            highp vec2 _1058 = (abs(_1026) - uData[57].zw) + vec2(_1054);
            highp float _1060 = (_1033 < 0.0) ? (-1.0) : 1.0;
            highp float _1063 = (_1026.y < 0.0) ? (-1.0) : 1.0;
            highp float _1065 = _1058.x;
            bool _1071;
            if (_1065 > 0.0)
            {
                _1071 = _1058.y > 0.0;
            }
            else
            {
                _1071 = false;
            }
            highp vec2 _1085;
            if (_1071)
            {
                _1085 = normalize(_1058) * vec2(_1060, _1063);
            }
            else
            {
                highp vec2 _1082;
                if (_1065 > _1058.y)
                {
                    _1082 = vec2(_1060, 0.0);
                }
                else
                {
                    _1082 = vec2(0.0, _1063);
                }
                _1085 = _1082;
            }
            _1093 = (min(max(_1065, _1058.y), 0.0) + length(max(_1058, vec2(0.0)))) - _1054;
            _1094 = _1085;
        }
        else
        {
            _1093 = -1000000000.0;
            _1094 = vec2(0.0);
        }
        bool _1098;
        if (_1016)
        {
            _1098 = uData[59].w < 3.5;
        }
        else
        {
            _1098 = false;
        }
        bool _1102;
        if (_1098)
        {
            _1102 = !_1015;
        }
        else
        {
            _1102 = false;
        }
        highp vec4 _1147;
        highp vec4 _1148;
        highp vec2 _1149;
        highp vec2 _1150;
        highp float _1151;
        highp vec2 _1152;
        highp vec2 _1153;
        highp vec2 _1154;
        highp vec2 _1155;
        highp float _1156;
        highp float _1157;
        highp float _1158;
        highp float _1159;
        if (_1102)
        {
            highp float _1105 = 1.0 - _1093;
            bool _1106 = _1105 < _173;
            highp vec4 _1122;
            highp vec2 _1123;
            highp vec2 _1124;
            highp float _1125;
            highp vec2 _1126;
            highp float _1127;
            if (_1106)
            {
                _1122 = _151;
                _1123 = _169;
                _1124 = uData[57].yw;
                _1125 = _175;
                _1126 = _167;
                _1127 = _173;
            }
            else
            {
                bool _1110 = _1105 < _171;
                highp vec2 _1114;
                if (_1110)
                {
                    _1114 = uData[57].yw;
                }
                else
                {
                    _1114 = _153;
                }
                bvec4 _1115 = bvec4(_1110);
                bvec2 _1118 = bvec2(_1110);
                _1122 = vec4(_1115.x ? uData[59].x : _148.x, _1115.y ? uData[59].y : _148.y, _1115.z ? uData[59].z : _148.z, _1115.w ? uData[59].w : _148.w);
                _1123 = _1114;
                _1124 = _169;
                _1125 = _1110 ? _175 : _155;
                _1126 = vec2(_1118.x ? vec2(0.0).x : _157.x, _1118.y ? vec2(0.0).y : _157.y);
                _1127 = _1110 ? _1105 : _171;
            }
            bvec4 _1128 = bvec4(_1106);
            bvec2 _1130 = bvec2(_1106);
            highp vec2 _1133 = -_1094;
            bool _1134 = _1105 < _165;
            highp vec2 _1142;
            highp float _1143;
            if (_1134)
            {
                _1142 = _161;
                _1143 = _165;
            }
            else
            {
                bool _1138 = _1105 < _163;
                bvec2 _1139 = bvec2(_1138);
                _1142 = vec2(_1139.x ? _1133.x : _159.x, _1139.y ? _1133.y : _159.y);
                _1143 = _1138 ? _1105 : _163;
            }
            bvec2 _1144 = bvec2(_1134);
            _1147 = _1122;
            _1148 = vec4(_1128.x ? uData[59].x : _151.x, _1128.y ? uData[59].y : _151.y, _1128.z ? uData[59].z : _151.z, _1128.w ? uData[59].w : _151.w);
            _1149 = _1123;
            _1150 = _1124;
            _1151 = _1125;
            _1152 = _1126;
            _1153 = vec2(_1130.x ? vec2(0.0).x : _167.x, _1130.y ? vec2(0.0).y : _167.y);
            _1154 = _1142;
            _1155 = vec2(_1144.x ? _1133.x : _161.x, _1144.y ? _1133.y : _161.y);
            _1156 = _1143;
            _1157 = _1134 ? _1105 : _165;
            _1158 = _1127;
            _1159 = _1106 ? _1105 : _173;
        }
        else
        {
            _1147 = _148;
            _1148 = _151;
            _1149 = _153;
            _1150 = _169;
            _1151 = _155;
            _1152 = _157;
            _1153 = _167;
            _1154 = _159;
            _1155 = _161;
            _1156 = _163;
            _1157 = _165;
            _1158 = _171;
            _1159 = _173;
        }
        highp float _1161 = max(uData[1].x, 9.9999997473787516355514526367188e-05);
        highp float _1166 = max(_1161 - abs(_1159 - _1158), 0.0) / _1161;
        highp float _1167 = _1166 * _1166;
        highp float _1168 = _1167 * 0.5;
        highp float _1173;
        if (_1158 < _1159)
        {
            _1173 = 1.0 - _1168;
        }
        else
        {
            _1173 = _1168;
        }
        highp float _1177 = min(_1159, _1158) - ((_1167 * _1161) * 0.25);
        highp float _1182 = max(_1161 - abs(_1157 - _1156), 0.0) / _1161;
        highp float _1183 = _1182 * _1182;
        highp float _1184 = _1183 * 0.5;
        highp float _1189;
        if (_1156 < _1157)
        {
            _1189 = 1.0 - _1184;
        }
        else
        {
            _1189 = _1184;
        }
        highp float _1193 = min(_1157, _1156) - ((_1183 * _1161) * 0.25);
        highp float _1197;
        if (_1015)
        {
            _1197 = max(_1177, _1093);
        }
        else
        {
            _1197 = _1177;
        }
        highp float _1199 = uData[2].z * 1.25;
        bool _1200 = _1199 <= 1.25;
        highp float _1205 = clamp(0.5 - (max(_1197, _1093) / (_1200 ? 1.39999997615814208984375 : 1.0)), 0.0, 1.0);
        bool _1211;
        if (uData[11].w > 0.0)
        {
            _1211 = _1205 < 1.0;
        }
        else
        {
            _1211 = false;
        }
        highp float _1469;
        if (_1211)
        {
            highp vec2 _1215 = vTextureCoord - uData[11].yz;
            highp float _1217;
            highp float _1220;
            _1217 = 1000000000.0;
            _1220 = 1000000000.0;
            highp float _1221;
            highp float _1218;
            int _1222 = _115;
            for (;;)
            {
                bool _1230;
                if (_1222 < _181)
                {
                    _1230 = _1222 < 16;
                }
                else
                {
                    _1230 = false;
                }
                if (_1230)
                {
                    int _1232 = 3 * _1222;
                    int _1233 = 12 + _1232;
                    int _1239 = _1232 + 14;
                    bool _1247;
                    if (uData[_1239 * 1 + 0].w >= (-0.5))
                    {
                        _1247 = uData[_1239 * 1 + 0].w > 3.5;
                    }
                    else
                    {
                        _1247 = true;
                    }
                    highp float _1438;
                    if (_1247)
                    {
                        highp vec4 _1299 = min(uData[58], vec4(min(uData[57].z, uData[57].w)));
                        int _1302 = int(uData[59].z);
                        highp vec2 _1304 = _1215 - uData[57].xy;
                        highp float _1327;
                        if (_1304.x > 0.0)
                        {
                            highp float _1326;
                            if (_1304.y > 0.0)
                            {
                                _1326 = _1299.z;
                            }
                            else
                            {
                                _1326 = _1299.y;
                            }
                            _1327 = _1326;
                        }
                        else
                        {
                            highp float _1318;
                            if (_1304.y > 0.0)
                            {
                                _1318 = _1299.w;
                            }
                            else
                            {
                                _1318 = _1299.x;
                            }
                            _1327 = _1318;
                        }
                        highp vec2 _1331 = (abs(_1304) - uData[57].zw) + vec2(_1327);
                        highp float _1341;
                        _1341 = (min(max(_1331.x, _1331.y), 0.0) + length(max(_1331, vec2(0.0)))) - _1327;
                        highp float _1342;
                        int _1344 = 0;
                        for (;;)
                        {
                            bool _1352;
                            if (_1344 < _1302)
                            {
                                _1352 = _1344 < 4;
                            }
                            else
                            {
                                _1352 = false;
                            }
                            if (_1352)
                            {
                                int _1354 = 14 - _1344;
                                int _1355 = 3 * _1354;
                                int _1356 = 12 + _1355;
                                int _1359 = _1355 + 13;
                                if (uData[_1359 * 1 + 0].x == 0.0)
                                {
                                    _1342 = _1341;
                                    int _1345 = _1344 + 1;
                                    _1341 = _1342;
                                    _1344 = _1345;
                                    continue;
                                }
                                highp float _1368 = clamp(uData[_1359 * 1 + 0].x / uData[_1359 * 1 + 0].y, 0.0, 1.0);
                                bool _1370 = uData[_1356 * 1 + 0].x < 0.5;
                                highp float _1376;
                                if (_1370)
                                {
                                    _1376 = _1215.y;
                                }
                                else
                                {
                                    _1376 = _1215.x;
                                }
                                highp float _1382;
                                if (_1370)
                                {
                                    _1382 = _1215.x;
                                }
                                else
                                {
                                    _1382 = _1215.y;
                                }
                                highp float _1385 = uData[_1359 * 1 + 0].x * 0.5;
                                highp float _1388 = uData[_1356 * 1 + 0].w - uData[_1356 * 1 + 0].z;
                                highp float _1389 = smoothstep(0.0, 0.60000002384185791015625, _1368);
                                highp float _1415;
                                if (uData[_1359 * 1 + 0].w > 2.5)
                                {
                                    _1415 = max(((_1388 * 0.5) * (1.0 - _1389)) - abs(_1376 - ((uData[_1356 * 1 + 0].z + uData[_1356 * 1 + 0].w) * 0.5)), 0.0);
                                }
                                else
                                {
                                    highp float _1401;
                                    if (uData[_1359 * 1 + 0].w < 1.5)
                                    {
                                        _1401 = _1376 - uData[_1356 * 1 + 0].z;
                                    }
                                    else
                                    {
                                        _1401 = uData[_1356 * 1 + 0].w - _1376;
                                    }
                                    _1415 = max(_1401 - ((_1388 - _1385) * _1389), 0.0);
                                }
                                highp float _1418 = length(vec2(_1382 - uData[_1356 * 1 + 0].y, _1415)) - _1385;
                                highp float _1420 = uData[_1359 * 1 + 0].z * _1368;
                                highp float _1421 = -_1418;
                                highp float _1437;
                                do
                                {
                                    if (_1420 == 0.0)
                                    {
                                        _1437 = max(_1341, _1421);
                                        break;
                                    }
                                    _1437 = min(-_1420, max(_1341, _1421)) + length(max(vec2(_1420 + _1341, _1420 - _1418), vec2(0.0)));
                                    break;
                                } while(false);
                                _1342 = _1437;
                                int _1345 = _1344 + 1;
                                _1341 = _1342;
                                _1344 = _1345;
                                continue;
                            }
                            else
                            {
                                break;
                            }
                        }
                        _1438 = _1341;
                    }
                    else
                    {
                        highp vec2 _1252 = _1215 - uData[_1233 * 1 + 0].xy;
                        highp vec4 _1258 = min(uData[(_1232 + 13) * 1 + 0], vec4(min(uData[_1233 * 1 + 0].z, uData[_1233 * 1 + 0].w)));
                        highp float _1280;
                        if (_1252.x > 0.0)
                        {
                            highp float _1279;
                            if (_1252.y > 0.0)
                            {
                                _1279 = _1258.z;
                            }
                            else
                            {
                                _1279 = _1258.y;
                            }
                            _1280 = _1279;
                        }
                        else
                        {
                            highp float _1271;
                            if (_1252.y > 0.0)
                            {
                                _1271 = _1258.w;
                            }
                            else
                            {
                                _1271 = _1258.x;
                            }
                            _1280 = _1271;
                        }
                        highp vec2 _1284 = (abs(_1252) - uData[_1233 * 1 + 0].zw) + vec2(_1280);
                        _1438 = (min(max(_1284.x, _1284.y), 0.0) + length(max(_1284, vec2(0.0)))) - _1280;
                    }
                    bool _1439 = _1438 < _1220;
                    if (_1439)
                    {
                        _1218 = _1220;
                    }
                    else
                    {
                        _1218 = (_1438 < _1217) ? _1438 : _1217;
                    }
                    _1221 = _1439 ? _1438 : _1220;
                    _1217 = _1218;
                    _1220 = _1221;
                    _1222++;
                    continue;
                }
                else
                {
                    break;
                }
            }
            highp float _1447 = max(uData[1].x, 9.9999997473787516355514526367188e-05);
            highp float _1452 = max(_1447 - abs(_1220 - _1217), 0.0) / _1447;
            highp float _1461 = 1.0 - clamp((min(_1220, _1217) - (((_1452 * _1452) * _1447) * 0.25)) / uData[11].x, 0.0, 1.0);
            _1469 = ((uData[11].w * _1461) * _1461) * clamp(mix(_1148.y, _1147.y, _1173), 0.0, 1.0);
        }
        else
        {
            _1469 = 0.0;
        }
        bool _1470 = _1205 <= 0.0;
        bool _1474;
        if (_1470)
        {
            _1474 = _1469 <= 0.00200000009499490261077880859375;
        }
        else
        {
            _1474 = false;
        }
        if (_1474)
        {
            discard;
        }
        if (vColor.x < 0.5)
        {
            _2027 = vec4(0.0, 0.0, 0.0, _1205 + ((1.0 - _1205) * _1469));
            break;
        }
        if (_1470)
        {
            discard;
        }
        highp vec4 _1489 = mix(_1148, _1147, vec4(_1173));
        highp vec2 _1491 = mix(_1155, _1154, vec2(_1189));
        bool _1495;
        if (_1015)
        {
            _1495 = _1093 > _1193;
        }
        else
        {
            _1495 = false;
        }
        bvec2 _1497 = bvec2(_1495);
        highp vec2 _1498 = vec2(_1497.x ? _1094.x : _1491.x, _1497.y ? _1094.y : _1491.y);
        highp vec2 _1499 = vec2(_1173);
        highp vec2 _1503 = mix(_1153, _1152, _1499) * min(length(_1498), 1.0);
        highp float _1505 = max(0.0, -(_1495 ? _1093 : _1193));
        highp float _1506 = mix(_175, _1151, _1173);
        highp float _1510 = clamp(_1506 / (3.0 * uData[1].z), 9.9999997473787516355514526367188e-05, 1.0);
        highp float _1511 = -_1505;
        highp float _1514 = exp(_1511 / (uData[1].z * _1510));
        highp float _1524 = _1489.y;
        highp float _1558;
        highp float _1559;
        highp vec2 _1560;
        if (_146)
        {
            highp float _1542 = max(min(uData[5].y * _1506, uData[6].w), 1.0);
            highp float _1545 = clamp(1.0 - (_1505 / _1542), 0.0, 1.0);
            highp float _1550 = (((uData[5].z * _1542) * _1524) * _1545) * _1545;
            _1558 = _1545;
            _1559 = _1550;
            _1560 = clamp(((vTextureCoord - (_1498 * _1550)) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        else
        {
            _1558 = 0.0;
            _1559 = 0.0;
            _1560 = clamp(((vTextureCoord + (_1498 * (((uData[2].x * _1510) * _1524) * _1514))) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        highp vec4 _1564 = textureLod(uSampler, _1560, 0.0);
        bool _1566 = uData[4].w > 0.5;
        highp vec4 _1574;
        if (_1566)
        {
            _1574 = textureLod(uTex1, _1560, 0.0);
        }
        else
        {
            _1574 = _1564;
        }
        bool _1579;
        if (_146)
        {
            _1579 = uData[6].y > 0.0;
        }
        else
        {
            _1579 = false;
        }
        bool _1583;
        if (_1579)
        {
            _1583 = _1559 > 0.5;
        }
        else
        {
            _1583 = false;
        }
        highp vec4 _1644;
        highp vec4 _1645;
        if (_1583)
        {
            highp vec2 _1591 = (_1498 * ((_1559 * 0.039999999105930328369140625) * uData[6].y)) * uData[0].zw;
            highp vec2 _1593 = clamp(_1560 + _1591, vec2(0.0), vec2(1.0));
            highp vec2 _1595 = clamp(_1560 - _1591, vec2(0.0), vec2(1.0));
            highp vec4 _1599 = textureLod(uSampler, _1593, 0.0);
            highp float _1604 = _1564.w;
            highp float _1605 = (_1599.x / max(_1599.w, 9.9999997473787516355514526367188e-05)) * _1604;
            highp vec4 _1606 = _1564;
            _1606.x = _1605;
            highp vec4 _1610 = textureLod(uSampler, _1595, 0.0);
            highp float _1615 = (_1610.z / max(_1610.w, 9.9999997473787516355514526367188e-05)) * _1604;
            _1606.z = _1615;
            highp vec4 _1643;
            if (_1566)
            {
                highp vec4 _1625 = textureLod(uTex1, _1593, 0.0);
                highp vec4 _1632 = _1574;
                _1632.x = (_1625.x / max(_1625.w, 9.9999997473787516355514526367188e-05)) * _1574.w;
                highp vec4 _1636 = textureLod(uTex1, _1595, 0.0);
                _1632.z = (_1636.z / max(_1636.w, 9.9999997473787516355514526367188e-05)) * _1574.w;
                _1643 = _1632;
            }
            else
            {
                highp vec4 _1620 = _1574;
                _1620.x = _1605;
                _1620.z = _1615;
                _1643 = _1620;
            }
            _1644 = _1643;
            _1645 = _1606;
        }
        else
        {
            _1644 = _1574;
            _1645 = _1564;
        }
        bool _1647 = uData[4].x > 1.5;
        highp float _1661;
        if (_1647)
        {
            _1661 = uData[3].w;
        }
        else
        {
            highp float _1659;
            if ((uData[6].x - 2.0 * trunc(uData[6].x / 2.0)) > 0.5)
            {
                _1659 = 1.0;
            }
            else
            {
                _1659 = _1645.w;
            }
            _1661 = _1659;
        }
        highp vec4 _1670 = vec4(_1645.xyz / vec3(max(_1645.w, 9.9999997473787516355514526367188e-05)), 1.0);
        highp vec4 _1679 = vec4(_1644.xyz / vec3(max(_1644.w, 9.9999997473787516355514526367188e-05)), 1.0);
        highp float _1686;
        if (_1647)
        {
            _1686 = 1.0;
        }
        else
        {
            _1686 = (uData[4].z > 0.5) ? uData[4].x : 0.0;
        }
        bool _1690;
        if (_146)
        {
            _1690 = !_1647;
        }
        else
        {
            _1690 = false;
        }
        highp float _1699;
        if (_1690)
        {
            _1699 = _1686 * (1.0 - ((_1558 * _1558) * (1.0 - smoothstep(0.800000011920928955078125, 1.0, _1686))));
        }
        else
        {
            _1699 = _1686;
        }
        highp float _1702 = 1.0 - _1699;
        highp float _1710;
        if (_146)
        {
            _1710 = _1558;
        }
        else
        {
            _1710 = _1514 * _1514;
        }
        highp float _1713 = clamp(((uData[2].y * _1524) * _1710) * _1702, 0.0, 1.0);
        highp vec4 _1719 = ((_1679 * _1713) + ((mix(_1679, _1670, vec4(clamp(_1489.x, 0.0, 1.0))) * _1702) * (1.0 - _1713))) + (uData[3] * _1699);
        highp vec4 _1762;
        if (_1647)
        {
            _1762 = vec4(uData[3].xyz / vec3(max(uData[3].w, 9.9999997473787516355514526367188e-05)), 1.0);
        }
        else
        {
            highp vec4 _1726 = _1719 + (_1670 * (1.0 - _1719.w));
            highp vec4 _1752;
            if (uData[7].w < 1.0)
            {
                highp vec3 _1731 = _1726.xyz;
                highp float _1732 = dot(_1731, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875));
                highp float _1733 = 0.60000002384185791015625 * uData[7].w;
                highp float _1735 = max(uData[7].w - _1733, 9.9999997473787516355514526367188e-05);
                highp float _1747;
                if (_1732 <= _1733)
                {
                    _1747 = _1732;
                }
                else
                {
                    _1747 = _1733 + (_1735 * (1.0 - exp((-(_1732 - _1733)) / _1735)));
                }
                highp vec3 _1750 = _1731 * (_1747 / max(_1732, 9.9999997473787516355514526367188e-05));
                _1752 = vec4(_1750.x, _1750.y, _1750.z, _1726.w);
            }
            else
            {
                _1752 = _1726;
            }
            _1762 = _1752;
        }
        highp float _1765 = dot(_1498, uData[9].xy);
        highp float _1766 = max(_1765, 0.0);
        highp float _1768 = max(-_1765, 0.0);
        highp float _1769 = abs(_1765);
        bool _1773;
        if (_146)
        {
            _1773 = uData[6].z > 0.0;
        }
        else
        {
            _1773 = false;
        }
        bool _1775 = uData[10].x > 0.0;
        highp float _1803;
        if (_1775)
        {
            _1803 = 0.0;
        }
        else
        {
            highp float _1802;
            if (_1773)
            {
                _1802 = (uData[6].z * (1.0 - smoothstep(0.20000000298023223876953125, 0.699999988079071044921875, _1769))) * exp((-max(0.0, -_1197)) / (uData[2].z * 2.5));
            }
            else
            {
                highp float _1787;
                if (_1200)
                {
                    _1787 = 0.699999988079071044921875;
                }
                else
                {
                    _1787 = uData[2].z * 0.625;
                }
                _1802 = uData[8].x * (1.0 - smoothstep(0.0, _1787, -_1197));
            }
            _1803 = _1802;
        }
        highp float _1813;
        if (_146)
        {
            _1813 = max((uData[5].w * _1558) * _1558, _1803) * min(_1524, 1.0);
        }
        else
        {
            _1813 = 0.0;
        }
        highp float _1816 = _1661 * (1.0 - _1813);
        highp vec4 _1822 = vec4(_1762.xyz * _1816, _1816 + _1813);
        highp float _1844;
        if (_146)
        {
            highp float _1843;
            if (_1773)
            {
                _1843 = uData[6].z * max(smoothstep(0.75, 1.0, _1769), max(_1503.x, _1503.y));
            }
            else
            {
                _1843 = 0.25;
            }
            _1844 = _1843;
        }
        else
        {
            _1844 = (0.449999988079071044921875 * ((_1766 * sqrt(_1766)) + ((0.75 * _1768) * sqrt(_1768)))) + 0.0599999986588954925537109375;
        }
        highp float _1880;
        if (_1773)
        {
            _1880 = exp((-max(0.0, -_1197)) / _1199);
        }
        else
        {
            highp float _1874;
            if (_146)
            {
                highp float _1873;
                if (_1200)
                {
                    highp float _1868 = -_1197;
                    _1873 = smoothstep(0.0, 0.89999997615814208984375, _1868) * (1.0 - smoothstep(1.5, 2.400000095367431640625, _1868));
                }
                else
                {
                    highp float _1861 = -_1197;
                    _1873 = smoothstep(uData[2].z * 0.3125, uData[2].z * 0.625, _1861) * (1.0 - smoothstep(uData[2].z * 1.5, uData[2].z * 2.0, _1861));
                }
                _1874 = _1873;
            }
            else
            {
                _1874 = exp((-max(0.0, -_1197)) / uData[2].z);
            }
            _1880 = _1874;
        }
        highp float _1892;
        if (_1775)
        {
            _1892 = 0.0;
        }
        else
        {
            highp float _1890;
            if (_146)
            {
                _1890 = 0.0;
            }
            else
            {
                _1890 = (0.039999999105930328369140625 * exp(_1511 / (uData[1].w * clamp(_1506 / (3.0 * uData[1].w), 9.9999997473787516355514526367188e-05, 1.0)))) * _1766;
            }
            _1892 = (_1880 * _1844) + _1890;
        }
        highp vec2 _1893 = mix(_1150, _1149, _1499);
        highp float _1897 = _1893.y;
        highp float _1903 = clamp((vTextureCoord.y - (_1893.x - _1897)) / max(2.0 * _1897, 9.9999997473787516355514526367188e-05), 0.0, 1.0);
        highp float _1921;
        if (uData[4].z > 0.5)
        {
            _1921 = uData[4].y + ((uData[7].x + ((uData[7].y - uData[7].x) * _1903)) + (uData[7].z * (1.0 - smoothstep(0.0, 0.37999999523162841796875, _1903))));
        }
        else
        {
            _1921 = 0.0;
        }
        highp vec3 _1931 = _1822.xyz + vec3(clamp((_1921 + _1489.z) + ((_1524 * uData[2].w) * _1892), 0.0, 1.0));
        highp vec4 _2003;
        if (_1775)
        {
            highp vec2 _1941;
            if (dot(_1498, _1498) > 9.9999999392252902907785028219223e-09)
            {
                _1941 = normalize(_1498);
            }
            else
            {
                _1941 = vec2(0.0);
            }
            highp float _1942 = dot(_1941, uData[9].xy);
            highp float _1944 = mix(8.0, 1.0, uData[9].z);
            highp float _1952 = pow(max(_1942, 0.0), _1944) + (uData[9].w * pow(max(-_1942, 0.0), _1944));
            highp float _1953 = min(_1524, 1.0);
            highp float _1960 = -_1197;
            highp float _1962 = smoothstep(-0.5, 0.5, _1960);
            highp float _1964 = -max(0.0, _1960);
            highp vec3 _2001 = (_1931.xyz * (1.0 - (((uData[10].z * (1.0 - abs(_1942))) * (_1962 * exp(_1964 / max(uData[2].z * 2.5, 0.001000000047497451305389404296875)))) * _1953))) + vec3(_1953 * (((uData[10].x * max(_1952, max(_1503.x, uData[9].w * _1503.y))) * (_1962 * exp(_1964 / max(uData[8].y, 0.001000000047497451305389404296875)))) + ((uData[10].y * _1952) * (smoothstep(uData[8].y - 0.5, uData[8].y + 0.5, _1960) * exp((-max(0.0, _1960 - uData[8].y)) / max(uData[8].z, 0.001000000047497451305389404296875))))));
            _2003 = vec4(_2001.x, _2001.y, _2001.z, _1822.w);
        }
        else
        {
            _2003 = vec4(_1931.x, _1931.y, _1931.z, _1822.w);
        }
        highp vec4 _2004 = clamp(_2003, vec4(0.0), vec4(1.0));
        highp float _2011 = max(_2004.w, max(_2004.x, max(_2004.y, _2004.z)));
        highp vec4 _2012 = _2004;
        _2012.w = _2011;
        highp vec3 _2023 = _2012.xyz + vec3(((fract(52.98291778564453125 * fract(dot(vTextureCoord, vec2(0.067110560834407806396484375, 0.005837149918079376220703125)))) - 0.5) * uData[5].x) * _2011);
        _2027 = clamp(vec4(_2023.x, _2023.y, _2023.z, _2012.w), vec4(0.0), vec4(1.0)) * _1205;
        break;
    } while(false);
    out_var_SV_Target0 = _2027;
}

