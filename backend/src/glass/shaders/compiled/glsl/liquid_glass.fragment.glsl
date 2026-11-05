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
    highp vec4 _2007;
    do
    {
        int _114 = int((vColor.y * 255.0) + 0.5);
        int _119 = int((vColor.z * 255.0) + 0.5);
        bool _145 = uData[5].y > 0.0;
        highp vec4 _147;
        highp vec4 _150;
        highp vec2 _152;
        highp float _154;
        highp vec2 _156;
        highp vec2 _158;
        highp vec2 _160;
        highp float _162;
        highp float _164;
        highp vec2 _166;
        highp vec2 _168;
        highp float _170;
        highp float _172;
        highp float _174;
        _147 = vec4(0.0);
        _150 = vec4(0.0);
        _152 = vec2(0.0, 1.0);
        _154 = 1000000000.0;
        _156 = vec2(0.0);
        _158 = vec2(0.0);
        _160 = vec2(0.0);
        _162 = 1000000000.0;
        _164 = 1000000000.0;
        _166 = vec2(0.0);
        _168 = vec2(0.0, 1.0);
        _170 = 1000000000.0;
        _172 = 1000000000.0;
        _174 = 1000000000.0;
        highp vec4 _151;
        highp vec2 _161;
        highp float _165;
        highp vec2 _167;
        highp float _173;
        highp float _175;
        int _180;
        highp vec4 _148;
        highp vec2 _153;
        highp float _155;
        highp vec2 _157;
        highp vec2 _159;
        highp float _163;
        highp vec2 _169;
        highp float _171;
        int _176 = _114;
        for (;;)
        {
            _180 = _114 + _119;
            bool _185;
            if (_176 < _180)
            {
                _185 = _176 < 16;
            }
            else
            {
                _185 = false;
            }
            if (_185)
            {
                int _187 = 3 * _176;
                int _194 = _187 + 14;
                bool _202;
                if (uData[_194 * 1 + 0].w >= (-0.5))
                {
                    _202 = uData[_194 * 1 + 0].w > 3.5;
                }
                else
                {
                    _202 = true;
                }
                highp vec4 _212;
                highp vec4 _213;
                highp vec4 _214;
                if (_202)
                {
                    highp vec4 _210 = uData[59];
                    _210.z = 0.0;
                    _212 = _210;
                    _213 = uData[57];
                    _214 = uData[58];
                }
                else
                {
                    _212 = uData[_194 * 1 + 0];
                    _213 = uData[(12 + _187) * 1 + 0];
                    _214 = uData[(_187 + 13) * 1 + 0];
                }
                highp float _217 = min(_213.z, _213.w);
                highp vec4 _219 = min(_214, vec4(_217));
                highp vec2 _504;
                highp float _505;
                if (_202)
                {
                    highp vec4 _294 = min(uData[58], vec4(min(uData[57].z, uData[57].w)));
                    int _297 = int(uData[59].z);
                    highp vec2 _299 = vTextureCoord - uData[57].xy;
                    highp float _301 = _299.x;
                    highp float _322;
                    if (_301 > 0.0)
                    {
                        highp float _321;
                        if (_299.y > 0.0)
                        {
                            _321 = _294.z;
                        }
                        else
                        {
                            _321 = _294.y;
                        }
                        _322 = _321;
                    }
                    else
                    {
                        highp float _313;
                        if (_299.y > 0.0)
                        {
                            _313 = _294.w;
                        }
                        else
                        {
                            _313 = _294.x;
                        }
                        _322 = _313;
                    }
                    highp vec2 _326 = (abs(_299) - uData[57].zw) + vec2(_322);
                    highp float _328 = (_301 < 0.0) ? (-1.0) : 1.0;
                    highp float _331 = (_299.y < 0.0) ? (-1.0) : 1.0;
                    highp float _333 = _326.x;
                    bool _339;
                    if (_333 > 0.0)
                    {
                        _339 = _326.y > 0.0;
                    }
                    else
                    {
                        _339 = false;
                    }
                    highp vec2 _353;
                    if (_339)
                    {
                        _353 = normalize(_326) * vec2(_328, _331);
                    }
                    else
                    {
                        highp vec2 _350;
                        if (_333 > _326.y)
                        {
                            _350 = vec2(_328, 0.0);
                        }
                        else
                        {
                            _350 = vec2(0.0, _331);
                        }
                        _353 = _350;
                    }
                    highp vec2 _362;
                    highp float _365;
                    _362 = _353;
                    _365 = (min(max(_333, _326.y), 0.0) + length(max(_326, vec2(0.0)))) - _322;
                    highp vec2 _363;
                    highp float _366;
                    int _367 = 0;
                    for (;;)
                    {
                        bool _375;
                        if (_367 < _297)
                        {
                            _375 = _367 < 4;
                        }
                        else
                        {
                            _375 = false;
                        }
                        if (_375)
                        {
                            int _377 = 14 - _367;
                            int _378 = 3 * _377;
                            int _379 = 12 + _378;
                            int _382 = _378 + 13;
                            if (uData[_382 * 1 + 0].x == 0.0)
                            {
                                _363 = _362;
                                _366 = _365;
                                int _368 = _367 + 1;
                                _362 = _363;
                                _365 = _366;
                                _367 = _368;
                                continue;
                            }
                            highp float _391 = clamp(uData[_382 * 1 + 0].x / uData[_382 * 1 + 0].y, 0.0, 1.0);
                            bool _393 = uData[_379 * 1 + 0].x < 0.5;
                            highp float _401;
                            if (_393)
                            {
                                _401 = vTextureCoord.y;
                            }
                            else
                            {
                                _401 = vTextureCoord.x;
                            }
                            highp float _409;
                            if (_393)
                            {
                                _409 = vTextureCoord.x;
                            }
                            else
                            {
                                _409 = vTextureCoord.y;
                            }
                            highp float _411 = _409 - uData[_379 * 1 + 0].y;
                            highp float _412 = uData[_382 * 1 + 0].x * 0.5;
                            highp float _415 = uData[_379 * 1 + 0].w - uData[_379 * 1 + 0].z;
                            highp float _416 = smoothstep(0.0, 0.60000002384185791015625, _391);
                            highp float _445;
                            highp float _446;
                            if (uData[_382 * 1 + 0].w > 2.5)
                            {
                                highp float _436 = _401 - ((uData[_379 * 1 + 0].z + uData[_379 * 1 + 0].w) * 0.5);
                                _445 = (_436 < 0.0) ? 1.0 : (-1.0);
                                _446 = max(((_415 * 0.5) * (1.0 - _416)) - abs(_436), 0.0);
                            }
                            else
                            {
                                bool _422 = uData[_382 * 1 + 0].w < 1.5;
                                highp float _428;
                                if (_422)
                                {
                                    _428 = _401 - uData[_379 * 1 + 0].z;
                                }
                                else
                                {
                                    _428 = uData[_379 * 1 + 0].w - _401;
                                }
                                _445 = _422 ? 1.0 : (-1.0);
                                _446 = max(_428 - ((_415 - _412) * _416), 0.0);
                            }
                            highp float _448 = length(vec2(_411, _446));
                            highp float _449 = _448 - _412;
                            highp vec2 _464;
                            if (_448 > 0.0)
                            {
                                highp vec2 _458 = vec2(-_411, (-_446) * _445) / vec2(_448);
                                highp vec2 _463;
                                if (uData[_379 * 1 + 0].x > 0.5)
                                {
                                    _463 = _458.yx;
                                }
                                else
                                {
                                    _463 = _458;
                                }
                                _464 = _463;
                            }
                            else
                            {
                                _464 = vec2(0.0);
                            }
                            highp float _466 = uData[_382 * 1 + 0].z * _391;
                            highp vec2 _470 = max(vec2(_466 + _365, _466 - _449), vec2(0.0));
                            highp float _471 = length(_470);
                            bool _476;
                            if (_466 > 0.0)
                            {
                                _476 = _471 > 0.0;
                            }
                            else
                            {
                                _476 = false;
                            }
                            highp vec2 _491;
                            if (_476)
                            {
                                _491 = ((_362 * _470.x) + (_464 * _470.y)) / vec2(_471);
                            }
                            else
                            {
                                bvec2 _482 = bvec2((-_449) > _365);
                                _491 = vec2(_482.x ? _464.x : _362.x, _482.y ? _464.y : _362.y);
                            }
                            highp float _492 = -_449;
                            highp float _503;
                            do
                            {
                                if (_466 == 0.0)
                                {
                                    _503 = max(_365, _492);
                                    break;
                                }
                                _503 = min(-_466, max(_365, _492)) + _471;
                                break;
                            } while(false);
                            _363 = _491;
                            _366 = _503;
                            int _368 = _367 + 1;
                            _362 = _363;
                            _365 = _366;
                            _367 = _368;
                            continue;
                        }
                        else
                        {
                            break;
                        }
                    }
                    _504 = _362;
                    _505 = _365;
                }
                else
                {
                    highp vec2 _224 = vTextureCoord - _213.xy;
                    highp float _226 = _224.x;
                    highp float _247;
                    if (_226 > 0.0)
                    {
                        highp float _246;
                        if (_224.y > 0.0)
                        {
                            _246 = _219.z;
                        }
                        else
                        {
                            _246 = _219.y;
                        }
                        _247 = _246;
                    }
                    else
                    {
                        highp float _238;
                        if (_224.y > 0.0)
                        {
                            _238 = _219.w;
                        }
                        else
                        {
                            _238 = _219.x;
                        }
                        _247 = _238;
                    }
                    highp vec2 _251 = (abs(_224) - _213.zw) + vec2(_247);
                    highp float _253 = (_226 < 0.0) ? (-1.0) : 1.0;
                    highp float _256 = (_224.y < 0.0) ? (-1.0) : 1.0;
                    highp float _258 = _251.x;
                    bool _264;
                    if (_258 > 0.0)
                    {
                        _264 = _251.y > 0.0;
                    }
                    else
                    {
                        _264 = false;
                    }
                    highp vec2 _278;
                    if (_264)
                    {
                        _278 = normalize(_251) * vec2(_253, _256);
                    }
                    else
                    {
                        highp vec2 _275;
                        if (_258 > _251.y)
                        {
                            _275 = vec2(_253, 0.0);
                        }
                        else
                        {
                            _275 = vec2(0.0, _256);
                        }
                        _278 = _275;
                    }
                    _504 = _278;
                    _505 = (min(max(_258, _251.y), 0.0) + length(max(_251, vec2(0.0)))) - _247;
                }
                highp vec2 _653;
                if (uData[10].w > 0.0)
                {
                    highp float _514 = (uData[9].x < 0.0) ? (-1.0) : 1.0;
                    highp float _517 = (uData[9].y < 0.0) ? (-1.0) : 1.0;
                    highp float _537;
                    if (_514 < 0.0)
                    {
                        highp float _536;
                        if (_517 < 0.0)
                        {
                            _536 = _219.x;
                        }
                        else
                        {
                            _536 = _219.w;
                        }
                        _537 = _536;
                    }
                    else
                    {
                        highp float _529;
                        if (_517 < 0.0)
                        {
                            _529 = _219.y;
                        }
                        else
                        {
                            _529 = _219.z;
                        }
                        _537 = _529;
                    }
                    highp vec2 _541 = max(_213.zw - vec2(_537), vec2(0.0));
                    highp vec2 _546 = (_213.xy + (vec2(_514, _517) * _541)) + (uData[9].xy * _537);
                    highp vec2 _561;
                    if (abs(uData[9].x) < 0.001000000047497451305389404296875)
                    {
                        highp float _554 = _541.x;
                        highp vec2 _560 = _546;
                        _560.x = clamp(vTextureCoord.x, _213.x - _554, _213.x + _554) + (_537 * uData[9].x);
                        _561 = _560;
                    }
                    else
                    {
                        _561 = _546;
                    }
                    highp vec2 _576;
                    if (abs(uData[9].y) < 0.001000000047497451305389404296875)
                    {
                        highp float _569 = _541.y;
                        highp vec2 _575 = _561;
                        _575.y = clamp(vTextureCoord.y, _213.y - _569, _213.y + _569) + (_537 * uData[9].y);
                        _576 = _575;
                    }
                    else
                    {
                        _576 = _561;
                    }
                    highp float _579 = max(uData[10].w - max(uData[8].w, 1.0), 0.0);
                    highp vec2 _584 = -uData[9].xy;
                    highp float _585 = _584.x;
                    highp float _587 = (_585 < 0.0) ? (-1.0) : 1.0;
                    highp float _588 = _584.y;
                    highp float _590 = (_588 < 0.0) ? (-1.0) : 1.0;
                    highp float _610;
                    if (_587 < 0.0)
                    {
                        highp float _609;
                        if (_590 < 0.0)
                        {
                            _609 = _219.x;
                        }
                        else
                        {
                            _609 = _219.w;
                        }
                        _610 = _609;
                    }
                    else
                    {
                        highp float _602;
                        if (_590 < 0.0)
                        {
                            _602 = _219.y;
                        }
                        else
                        {
                            _602 = _219.z;
                        }
                        _610 = _602;
                    }
                    highp vec2 _613 = max(_213.zw - vec2(_610), vec2(0.0));
                    highp vec2 _617 = (_213.xy + (vec2(_587, _590) * _613)) + (_584 * _610);
                    highp vec2 _632;
                    if (abs(_585) < 0.001000000047497451305389404296875)
                    {
                        highp float _625 = _613.x;
                        highp vec2 _631 = _617;
                        _631.x = clamp(vTextureCoord.x, _213.x - _625, _213.x + _625) + (_610 * _585);
                        _632 = _631;
                    }
                    else
                    {
                        _632 = _617;
                    }
                    highp vec2 _647;
                    if (abs(_588) < 0.001000000047497451305389404296875)
                    {
                        highp float _640 = _613.y;
                        highp vec2 _646 = _632;
                        _646.y = clamp(vTextureCoord.y, _213.y - _640, _213.y + _640) + (_610 * _588);
                        _647 = _646;
                    }
                    else
                    {
                        _647 = _632;
                    }
                    _653 = vec2(1.0 - smoothstep(_579, uData[10].w, length(vTextureCoord - _576)), 1.0 - smoothstep(_579, uData[10].w, length(vTextureCoord - _647)));
                }
                else
                {
                    _653 = vec2(0.0);
                }
                bool _654 = _505 < _172;
                if (_654)
                {
                    _148 = _150;
                    _153 = _168;
                    _155 = _174;
                    _157 = _166;
                    _169 = _213.yw;
                    _171 = _172;
                }
                else
                {
                    bool _658 = _505 < _170;
                    highp vec2 _662;
                    if (_658)
                    {
                        _662 = _213.yw;
                    }
                    else
                    {
                        _662 = _152;
                    }
                    bvec4 _663 = bvec4(_658);
                    bvec2 _666 = bvec2(_658);
                    _148 = vec4(_663.x ? _212.x : _147.x, _663.y ? _212.y : _147.y, _663.z ? _212.z : _147.z, _663.w ? _212.w : _147.w);
                    _153 = _662;
                    _155 = _658 ? _217 : _154;
                    _157 = vec2(_666.x ? _653.x : _156.x, _666.y ? _653.y : _156.y);
                    _169 = _168;
                    _171 = _658 ? _505 : _170;
                }
                bvec4 _670 = bvec4(_654);
                _151 = vec4(_670.x ? _212.x : _150.x, _670.y ? _212.y : _150.y, _670.z ? _212.z : _150.z, _670.w ? _212.w : _150.w);
                bvec2 _671 = bvec2(_654);
                _167 = vec2(_671.x ? _653.x : _166.x, _671.y ? _653.y : _166.y);
                _173 = _654 ? _505 : _172;
                _175 = _654 ? _217 : _174;
                highp vec2 _984;
                highp float _985;
                if (_202)
                {
                    highp vec4 _730 = min(uData[58], vec4(min(uData[57].z, uData[57].w)));
                    int _733 = int(uData[59].z);
                    highp vec2 _839;
                    highp float _840;
                    if (uData[1].y > 0.0)
                    {
                        highp float _805 = (vTextureCoord.x - uData[57].x) + uData[57].z;
                        highp float _807 = (uData[57].x + uData[57].z) - vTextureCoord.x;
                        highp float _812 = (vTextureCoord.y - uData[57].y) + uData[57].w;
                        highp float _814 = (uData[57].y + uData[57].w) - vTextureCoord.y;
                        highp float _818 = min(min(_805, _807), min(_812, _814));
                        highp vec4 _823 = exp((vec4(_818) - vec4(_805, _807, _812, _814)) / vec4(uData[1].y));
                        highp float _824 = _823.x;
                        highp float _825 = _823.y;
                        highp float _827 = _823.z;
                        highp float _829 = _823.w;
                        highp float _830 = ((_824 + _825) + _827) + _829;
                        _839 = vec2(_825 - _824, _829 - _827) / vec2(_830);
                        _840 = (uData[1].y * log(_830)) - _818;
                    }
                    else
                    {
                        highp vec2 _739 = vTextureCoord - uData[57].xy;
                        highp float _741 = _739.x;
                        highp float _762;
                        if (_741 > 0.0)
                        {
                            highp float _761;
                            if (_739.y > 0.0)
                            {
                                _761 = _730.z;
                            }
                            else
                            {
                                _761 = _730.y;
                            }
                            _762 = _761;
                        }
                        else
                        {
                            highp float _753;
                            if (_739.y > 0.0)
                            {
                                _753 = _730.w;
                            }
                            else
                            {
                                _753 = _730.x;
                            }
                            _762 = _753;
                        }
                        highp vec2 _766 = (abs(_739) - uData[57].zw) + vec2(_762);
                        highp float _768 = (_741 < 0.0) ? (-1.0) : 1.0;
                        highp float _771 = (_739.y < 0.0) ? (-1.0) : 1.0;
                        highp float _773 = _766.x;
                        bool _779;
                        if (_773 > 0.0)
                        {
                            _779 = _766.y > 0.0;
                        }
                        else
                        {
                            _779 = false;
                        }
                        highp vec2 _793;
                        if (_779)
                        {
                            _793 = normalize(_766) * vec2(_768, _771);
                        }
                        else
                        {
                            highp vec2 _790;
                            if (_773 > _766.y)
                            {
                                _790 = vec2(_768, 0.0);
                            }
                            else
                            {
                                _790 = vec2(0.0, _771);
                            }
                            _793 = _790;
                        }
                        _839 = _793;
                        _840 = (min(max(_773, _766.y), 0.0) + length(max(_766, vec2(0.0)))) - _762;
                    }
                    highp vec2 _842;
                    highp float _845;
                    _842 = _839;
                    _845 = _840;
                    highp vec2 _843;
                    highp float _846;
                    int _847 = 0;
                    for (;;)
                    {
                        bool _855;
                        if (_847 < _733)
                        {
                            _855 = _847 < 4;
                        }
                        else
                        {
                            _855 = false;
                        }
                        if (_855)
                        {
                            int _857 = 14 - _847;
                            int _858 = 3 * _857;
                            int _859 = 12 + _858;
                            int _862 = _858 + 13;
                            if (uData[_862 * 1 + 0].x == 0.0)
                            {
                                _843 = _842;
                                _846 = _845;
                                int _848 = _847 + 1;
                                _842 = _843;
                                _845 = _846;
                                _847 = _848;
                                continue;
                            }
                            highp float _871 = clamp(uData[_862 * 1 + 0].x / uData[_862 * 1 + 0].y, 0.0, 1.0);
                            bool _873 = uData[_859 * 1 + 0].x < 0.5;
                            highp float _881;
                            if (_873)
                            {
                                _881 = vTextureCoord.y;
                            }
                            else
                            {
                                _881 = vTextureCoord.x;
                            }
                            highp float _889;
                            if (_873)
                            {
                                _889 = vTextureCoord.x;
                            }
                            else
                            {
                                _889 = vTextureCoord.y;
                            }
                            highp float _891 = _889 - uData[_859 * 1 + 0].y;
                            highp float _892 = uData[_862 * 1 + 0].x * 0.5;
                            highp float _895 = uData[_859 * 1 + 0].w - uData[_859 * 1 + 0].z;
                            highp float _896 = smoothstep(0.0, 0.60000002384185791015625, _871);
                            highp float _925;
                            highp float _926;
                            if (uData[_862 * 1 + 0].w > 2.5)
                            {
                                highp float _916 = _881 - ((uData[_859 * 1 + 0].z + uData[_859 * 1 + 0].w) * 0.5);
                                _925 = (_916 < 0.0) ? 1.0 : (-1.0);
                                _926 = max(((_895 * 0.5) * (1.0 - _896)) - abs(_916), 0.0);
                            }
                            else
                            {
                                bool _902 = uData[_862 * 1 + 0].w < 1.5;
                                highp float _908;
                                if (_902)
                                {
                                    _908 = _881 - uData[_859 * 1 + 0].z;
                                }
                                else
                                {
                                    _908 = uData[_859 * 1 + 0].w - _881;
                                }
                                _925 = _902 ? 1.0 : (-1.0);
                                _926 = max(_908 - ((_895 - _892) * _896), 0.0);
                            }
                            highp float _928 = length(vec2(_891, _926));
                            highp float _929 = _928 - _892;
                            highp vec2 _944;
                            if (_928 > 0.0)
                            {
                                highp vec2 _938 = vec2(-_891, (-_926) * _925) / vec2(_928);
                                highp vec2 _943;
                                if (uData[_859 * 1 + 0].x > 0.5)
                                {
                                    _943 = _938.yx;
                                }
                                else
                                {
                                    _943 = _938;
                                }
                                _944 = _943;
                            }
                            else
                            {
                                _944 = vec2(0.0);
                            }
                            highp float _946 = uData[_862 * 1 + 0].z * _871;
                            highp vec2 _950 = max(vec2(_946 + _845, _946 - _929), vec2(0.0));
                            highp float _951 = length(_950);
                            bool _956;
                            if (_946 > 0.0)
                            {
                                _956 = _951 > 0.0;
                            }
                            else
                            {
                                _956 = false;
                            }
                            highp vec2 _971;
                            if (_956)
                            {
                                _971 = ((_842 * _950.x) + (_944 * _950.y)) / vec2(_951);
                            }
                            else
                            {
                                bvec2 _962 = bvec2((-_929) > _845);
                                _971 = vec2(_962.x ? _944.x : _842.x, _962.y ? _944.y : _842.y);
                            }
                            highp float _972 = -_929;
                            highp float _983;
                            do
                            {
                                if (_946 == 0.0)
                                {
                                    _983 = max(_845, _972);
                                    break;
                                }
                                _983 = min(-_946, max(_845, _972)) + _951;
                                break;
                            } while(false);
                            _843 = _971;
                            _846 = _983;
                            int _848 = _847 + 1;
                            _842 = _843;
                            _845 = _846;
                            _847 = _848;
                            continue;
                        }
                        else
                        {
                            break;
                        }
                    }
                    _984 = _842;
                    _985 = _845;
                }
                else
                {
                    highp vec2 _719;
                    highp float _720;
                    if (_212.w < 0.5)
                    {
                        highp float _685 = (vTextureCoord.x - _213.x) + _213.z;
                        highp float _687 = (_213.x + _213.z) - vTextureCoord.x;
                        highp float _692 = (vTextureCoord.y - _213.y) + _213.w;
                        highp float _694 = (_213.y + _213.w) - vTextureCoord.y;
                        highp float _698 = min(min(_685, _687), min(_692, _694));
                        highp vec4 _703 = exp((vec4(_698) - vec4(_685, _687, _692, _694)) / vec4(uData[1].y));
                        highp float _704 = _703.x;
                        highp float _705 = _703.y;
                        highp float _707 = _703.z;
                        highp float _709 = _703.w;
                        highp float _710 = ((_704 + _705) + _707) + _709;
                        _719 = vec2(_705 - _704, _709 - _707) / vec2(_710);
                        _720 = (uData[1].y * log(_710)) - _698;
                    }
                    else
                    {
                        _719 = _504;
                        _720 = _505;
                    }
                    _984 = _719;
                    _985 = _720;
                }
                bool _986 = _985 < _164;
                if (_986)
                {
                    _159 = _160;
                    _163 = _164;
                }
                else
                {
                    bool _990 = _985 < _162;
                    bvec2 _991 = bvec2(_990);
                    _159 = vec2(_991.x ? _984.x : _158.x, _991.y ? _984.y : _158.y);
                    _163 = _990 ? _985 : _162;
                }
                bvec2 _994 = bvec2(_986);
                _161 = vec2(_994.x ? _984.x : _160.x, _994.y ? _984.y : _160.y);
                _165 = _986 ? _985 : _164;
                _147 = _148;
                _150 = _151;
                _152 = _153;
                _154 = _155;
                _156 = _157;
                _158 = _159;
                _160 = _161;
                _162 = _163;
                _164 = _165;
                _166 = _167;
                _168 = _169;
                _170 = _171;
                _172 = _173;
                _174 = _175;
                _176++;
                continue;
            }
            else
            {
                break;
            }
        }
        bool _1004;
        if (uData[59].w > 2.5)
        {
            _1004 = uData[59].w < 3.5;
        }
        else
        {
            _1004 = false;
        }
        bool _1005 = uData[59].w > 1.5;
        bool _1009;
        if (_1005)
        {
            _1009 = uData[59].w < 3.5;
        }
        else
        {
            _1009 = false;
        }
        highp float _1082;
        highp vec2 _1083;
        if (_1009)
        {
            highp vec2 _1015 = vTextureCoord - uData[57].xy;
            highp vec4 _1021 = min(uData[58], vec4(min(uData[57].z, uData[57].w)));
            highp float _1022 = _1015.x;
            highp float _1043;
            if (_1022 > 0.0)
            {
                highp float _1042;
                if (_1015.y > 0.0)
                {
                    _1042 = _1021.z;
                }
                else
                {
                    _1042 = _1021.y;
                }
                _1043 = _1042;
            }
            else
            {
                highp float _1034;
                if (_1015.y > 0.0)
                {
                    _1034 = _1021.w;
                }
                else
                {
                    _1034 = _1021.x;
                }
                _1043 = _1034;
            }
            highp vec2 _1047 = (abs(_1015) - uData[57].zw) + vec2(_1043);
            highp float _1049 = (_1022 < 0.0) ? (-1.0) : 1.0;
            highp float _1052 = (_1015.y < 0.0) ? (-1.0) : 1.0;
            highp float _1054 = _1047.x;
            bool _1060;
            if (_1054 > 0.0)
            {
                _1060 = _1047.y > 0.0;
            }
            else
            {
                _1060 = false;
            }
            highp vec2 _1074;
            if (_1060)
            {
                _1074 = normalize(_1047) * vec2(_1049, _1052);
            }
            else
            {
                highp vec2 _1071;
                if (_1054 > _1047.y)
                {
                    _1071 = vec2(_1049, 0.0);
                }
                else
                {
                    _1071 = vec2(0.0, _1052);
                }
                _1074 = _1071;
            }
            _1082 = (min(max(_1054, _1047.y), 0.0) + length(max(_1047, vec2(0.0)))) - _1043;
            _1083 = _1074;
        }
        else
        {
            _1082 = -1000000000.0;
            _1083 = vec2(0.0);
        }
        bool _1087;
        if (_1005)
        {
            _1087 = uData[59].w < 3.5;
        }
        else
        {
            _1087 = false;
        }
        bool _1091;
        if (_1087)
        {
            _1091 = !_1004;
        }
        else
        {
            _1091 = false;
        }
        highp vec4 _1136;
        highp vec4 _1137;
        highp vec2 _1138;
        highp vec2 _1139;
        highp float _1140;
        highp vec2 _1141;
        highp vec2 _1142;
        highp vec2 _1143;
        highp vec2 _1144;
        highp float _1145;
        highp float _1146;
        highp float _1147;
        highp float _1148;
        if (_1091)
        {
            highp float _1094 = 1.0 - _1082;
            bool _1095 = _1094 < _172;
            highp vec4 _1111;
            highp vec2 _1112;
            highp vec2 _1113;
            highp float _1114;
            highp vec2 _1115;
            highp float _1116;
            if (_1095)
            {
                _1111 = _150;
                _1112 = _168;
                _1113 = uData[57].yw;
                _1114 = _174;
                _1115 = _166;
                _1116 = _172;
            }
            else
            {
                bool _1099 = _1094 < _170;
                highp vec2 _1103;
                if (_1099)
                {
                    _1103 = uData[57].yw;
                }
                else
                {
                    _1103 = _152;
                }
                bvec4 _1104 = bvec4(_1099);
                bvec2 _1107 = bvec2(_1099);
                _1111 = vec4(_1104.x ? uData[59].x : _147.x, _1104.y ? uData[59].y : _147.y, _1104.z ? uData[59].z : _147.z, _1104.w ? uData[59].w : _147.w);
                _1112 = _1103;
                _1113 = _168;
                _1114 = _1099 ? _174 : _154;
                _1115 = vec2(_1107.x ? vec2(0.0).x : _156.x, _1107.y ? vec2(0.0).y : _156.y);
                _1116 = _1099 ? _1094 : _170;
            }
            bvec4 _1117 = bvec4(_1095);
            bvec2 _1119 = bvec2(_1095);
            highp vec2 _1122 = -_1083;
            bool _1123 = _1094 < _164;
            highp vec2 _1131;
            highp float _1132;
            if (_1123)
            {
                _1131 = _160;
                _1132 = _164;
            }
            else
            {
                bool _1127 = _1094 < _162;
                bvec2 _1128 = bvec2(_1127);
                _1131 = vec2(_1128.x ? _1122.x : _158.x, _1128.y ? _1122.y : _158.y);
                _1132 = _1127 ? _1094 : _162;
            }
            bvec2 _1133 = bvec2(_1123);
            _1136 = _1111;
            _1137 = vec4(_1117.x ? uData[59].x : _150.x, _1117.y ? uData[59].y : _150.y, _1117.z ? uData[59].z : _150.z, _1117.w ? uData[59].w : _150.w);
            _1138 = _1112;
            _1139 = _1113;
            _1140 = _1114;
            _1141 = _1115;
            _1142 = vec2(_1119.x ? vec2(0.0).x : _166.x, _1119.y ? vec2(0.0).y : _166.y);
            _1143 = _1131;
            _1144 = vec2(_1133.x ? _1122.x : _160.x, _1133.y ? _1122.y : _160.y);
            _1145 = _1132;
            _1146 = _1123 ? _1094 : _164;
            _1147 = _1116;
            _1148 = _1095 ? _1094 : _172;
        }
        else
        {
            _1136 = _147;
            _1137 = _150;
            _1138 = _152;
            _1139 = _168;
            _1140 = _154;
            _1141 = _156;
            _1142 = _166;
            _1143 = _158;
            _1144 = _160;
            _1145 = _162;
            _1146 = _164;
            _1147 = _170;
            _1148 = _172;
        }
        highp float _1150 = max(uData[1].x, 9.9999997473787516355514526367188e-05);
        highp float _1155 = max(_1150 - abs(_1148 - _1147), 0.0) / _1150;
        highp float _1156 = _1155 * _1155;
        highp float _1157 = _1156 * 0.5;
        highp float _1162;
        if (_1147 < _1148)
        {
            _1162 = 1.0 - _1157;
        }
        else
        {
            _1162 = _1157;
        }
        highp float _1166 = min(_1148, _1147) - ((_1156 * _1150) * 0.25);
        highp float _1171 = max(_1150 - abs(_1146 - _1145), 0.0) / _1150;
        highp float _1172 = _1171 * _1171;
        highp float _1173 = _1172 * 0.5;
        highp float _1178;
        if (_1145 < _1146)
        {
            _1178 = 1.0 - _1173;
        }
        else
        {
            _1178 = _1173;
        }
        highp float _1182 = min(_1146, _1145) - ((_1172 * _1150) * 0.25);
        highp float _1186;
        if (_1004)
        {
            _1186 = max(_1166, _1082);
        }
        else
        {
            _1186 = _1166;
        }
        highp float _1188 = uData[2].z * 1.25;
        bool _1189 = _1188 <= 1.25;
        highp float _1194 = clamp(0.5 - (max(_1186, _1082) / (_1189 ? 1.39999997615814208984375 : 1.0)), 0.0, 1.0);
        bool _1200;
        if (uData[11].w > 0.0)
        {
            _1200 = _1194 < 1.0;
        }
        else
        {
            _1200 = false;
        }
        highp float _1458;
        if (_1200)
        {
            highp vec2 _1204 = vTextureCoord - uData[11].yz;
            highp float _1206;
            highp float _1209;
            _1206 = 1000000000.0;
            _1209 = 1000000000.0;
            highp float _1210;
            highp float _1207;
            int _1211 = _114;
            for (;;)
            {
                bool _1219;
                if (_1211 < _180)
                {
                    _1219 = _1211 < 16;
                }
                else
                {
                    _1219 = false;
                }
                if (_1219)
                {
                    int _1221 = 3 * _1211;
                    int _1222 = 12 + _1221;
                    int _1228 = _1221 + 14;
                    bool _1236;
                    if (uData[_1228 * 1 + 0].w >= (-0.5))
                    {
                        _1236 = uData[_1228 * 1 + 0].w > 3.5;
                    }
                    else
                    {
                        _1236 = true;
                    }
                    highp float _1427;
                    if (_1236)
                    {
                        highp vec4 _1288 = min(uData[58], vec4(min(uData[57].z, uData[57].w)));
                        int _1291 = int(uData[59].z);
                        highp vec2 _1293 = _1204 - uData[57].xy;
                        highp float _1316;
                        if (_1293.x > 0.0)
                        {
                            highp float _1315;
                            if (_1293.y > 0.0)
                            {
                                _1315 = _1288.z;
                            }
                            else
                            {
                                _1315 = _1288.y;
                            }
                            _1316 = _1315;
                        }
                        else
                        {
                            highp float _1307;
                            if (_1293.y > 0.0)
                            {
                                _1307 = _1288.w;
                            }
                            else
                            {
                                _1307 = _1288.x;
                            }
                            _1316 = _1307;
                        }
                        highp vec2 _1320 = (abs(_1293) - uData[57].zw) + vec2(_1316);
                        highp float _1330;
                        _1330 = (min(max(_1320.x, _1320.y), 0.0) + length(max(_1320, vec2(0.0)))) - _1316;
                        highp float _1331;
                        int _1333 = 0;
                        for (;;)
                        {
                            bool _1341;
                            if (_1333 < _1291)
                            {
                                _1341 = _1333 < 4;
                            }
                            else
                            {
                                _1341 = false;
                            }
                            if (_1341)
                            {
                                int _1343 = 14 - _1333;
                                int _1344 = 3 * _1343;
                                int _1345 = 12 + _1344;
                                int _1348 = _1344 + 13;
                                if (uData[_1348 * 1 + 0].x == 0.0)
                                {
                                    _1331 = _1330;
                                    int _1334 = _1333 + 1;
                                    _1330 = _1331;
                                    _1333 = _1334;
                                    continue;
                                }
                                highp float _1357 = clamp(uData[_1348 * 1 + 0].x / uData[_1348 * 1 + 0].y, 0.0, 1.0);
                                bool _1359 = uData[_1345 * 1 + 0].x < 0.5;
                                highp float _1365;
                                if (_1359)
                                {
                                    _1365 = _1204.y;
                                }
                                else
                                {
                                    _1365 = _1204.x;
                                }
                                highp float _1371;
                                if (_1359)
                                {
                                    _1371 = _1204.x;
                                }
                                else
                                {
                                    _1371 = _1204.y;
                                }
                                highp float _1374 = uData[_1348 * 1 + 0].x * 0.5;
                                highp float _1377 = uData[_1345 * 1 + 0].w - uData[_1345 * 1 + 0].z;
                                highp float _1378 = smoothstep(0.0, 0.60000002384185791015625, _1357);
                                highp float _1404;
                                if (uData[_1348 * 1 + 0].w > 2.5)
                                {
                                    _1404 = max(((_1377 * 0.5) * (1.0 - _1378)) - abs(_1365 - ((uData[_1345 * 1 + 0].z + uData[_1345 * 1 + 0].w) * 0.5)), 0.0);
                                }
                                else
                                {
                                    highp float _1390;
                                    if (uData[_1348 * 1 + 0].w < 1.5)
                                    {
                                        _1390 = _1365 - uData[_1345 * 1 + 0].z;
                                    }
                                    else
                                    {
                                        _1390 = uData[_1345 * 1 + 0].w - _1365;
                                    }
                                    _1404 = max(_1390 - ((_1377 - _1374) * _1378), 0.0);
                                }
                                highp float _1407 = length(vec2(_1371 - uData[_1345 * 1 + 0].y, _1404)) - _1374;
                                highp float _1409 = uData[_1348 * 1 + 0].z * _1357;
                                highp float _1410 = -_1407;
                                highp float _1426;
                                do
                                {
                                    if (_1409 == 0.0)
                                    {
                                        _1426 = max(_1330, _1410);
                                        break;
                                    }
                                    _1426 = min(-_1409, max(_1330, _1410)) + length(max(vec2(_1409 + _1330, _1409 - _1407), vec2(0.0)));
                                    break;
                                } while(false);
                                _1331 = _1426;
                                int _1334 = _1333 + 1;
                                _1330 = _1331;
                                _1333 = _1334;
                                continue;
                            }
                            else
                            {
                                break;
                            }
                        }
                        _1427 = _1330;
                    }
                    else
                    {
                        highp vec2 _1241 = _1204 - uData[_1222 * 1 + 0].xy;
                        highp vec4 _1247 = min(uData[(_1221 + 13) * 1 + 0], vec4(min(uData[_1222 * 1 + 0].z, uData[_1222 * 1 + 0].w)));
                        highp float _1269;
                        if (_1241.x > 0.0)
                        {
                            highp float _1268;
                            if (_1241.y > 0.0)
                            {
                                _1268 = _1247.z;
                            }
                            else
                            {
                                _1268 = _1247.y;
                            }
                            _1269 = _1268;
                        }
                        else
                        {
                            highp float _1260;
                            if (_1241.y > 0.0)
                            {
                                _1260 = _1247.w;
                            }
                            else
                            {
                                _1260 = _1247.x;
                            }
                            _1269 = _1260;
                        }
                        highp vec2 _1273 = (abs(_1241) - uData[_1222 * 1 + 0].zw) + vec2(_1269);
                        _1427 = (min(max(_1273.x, _1273.y), 0.0) + length(max(_1273, vec2(0.0)))) - _1269;
                    }
                    bool _1428 = _1427 < _1209;
                    if (_1428)
                    {
                        _1207 = _1209;
                    }
                    else
                    {
                        _1207 = (_1427 < _1206) ? _1427 : _1206;
                    }
                    _1210 = _1428 ? _1427 : _1209;
                    _1206 = _1207;
                    _1209 = _1210;
                    _1211++;
                    continue;
                }
                else
                {
                    break;
                }
            }
            highp float _1436 = max(uData[1].x, 9.9999997473787516355514526367188e-05);
            highp float _1441 = max(_1436 - abs(_1209 - _1206), 0.0) / _1436;
            highp float _1450 = 1.0 - clamp((min(_1209, _1206) - (((_1441 * _1441) * _1436) * 0.25)) / uData[11].x, 0.0, 1.0);
            _1458 = ((uData[11].w * _1450) * _1450) * clamp(mix(_1137.y, _1136.y, _1162), 0.0, 1.0);
        }
        else
        {
            _1458 = 0.0;
        }
        bool _1459 = _1194 <= 0.0;
        bool _1463;
        if (_1459)
        {
            _1463 = _1458 <= 0.00200000009499490261077880859375;
        }
        else
        {
            _1463 = false;
        }
        if (_1463)
        {
            discard;
        }
        if (vColor.x < 0.5)
        {
            _2007 = vec4(0.0, 0.0, 0.0, _1194 + ((1.0 - _1194) * _1458));
            break;
        }
        if (_1459)
        {
            discard;
        }
        highp vec4 _1478 = mix(_1137, _1136, vec4(_1162));
        highp vec2 _1480 = mix(_1144, _1143, vec2(_1178));
        bool _1484;
        if (_1004)
        {
            _1484 = _1082 > _1182;
        }
        else
        {
            _1484 = false;
        }
        bvec2 _1486 = bvec2(_1484);
        highp vec2 _1487 = vec2(_1486.x ? _1083.x : _1480.x, _1486.y ? _1083.y : _1480.y);
        highp vec2 _1488 = vec2(_1162);
        highp vec2 _1492 = mix(_1142, _1141, _1488) * min(length(_1487), 1.0);
        highp float _1494 = max(0.0, -(_1484 ? _1082 : _1182));
        highp float _1495 = -_1494;
        highp float _1498 = exp(_1495 / uData[1].z);
        highp float _1504 = _1478.y;
        highp float _1538;
        highp float _1539;
        highp vec2 _1540;
        if (_145)
        {
            highp float _1522 = max(min(uData[5].y * mix(_174, _1140, _1162), uData[6].w), 1.0);
            highp float _1525 = clamp(1.0 - (_1494 / _1522), 0.0, 1.0);
            highp float _1530 = (((uData[5].z * _1522) * _1504) * _1525) * _1525;
            _1538 = _1525;
            _1539 = _1530;
            _1540 = clamp(((vTextureCoord - (_1487 * _1530)) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        else
        {
            _1538 = 0.0;
            _1539 = 0.0;
            _1540 = clamp(((vTextureCoord + (_1487 * ((uData[2].x * _1504) * _1498))) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        highp vec4 _1544 = textureLod(uSampler, _1540, 0.0);
        bool _1546 = uData[4].w > 0.5;
        highp vec4 _1554;
        if (_1546)
        {
            _1554 = textureLod(uTex1, _1540, 0.0);
        }
        else
        {
            _1554 = _1544;
        }
        bool _1559;
        if (_145)
        {
            _1559 = uData[6].y > 0.0;
        }
        else
        {
            _1559 = false;
        }
        bool _1563;
        if (_1559)
        {
            _1563 = _1539 > 0.5;
        }
        else
        {
            _1563 = false;
        }
        highp vec4 _1624;
        highp vec4 _1625;
        if (_1563)
        {
            highp vec2 _1571 = (_1487 * ((_1539 * 0.039999999105930328369140625) * uData[6].y)) * uData[0].zw;
            highp vec2 _1573 = clamp(_1540 + _1571, vec2(0.0), vec2(1.0));
            highp vec2 _1575 = clamp(_1540 - _1571, vec2(0.0), vec2(1.0));
            highp vec4 _1579 = textureLod(uSampler, _1573, 0.0);
            highp float _1584 = _1544.w;
            highp float _1585 = (_1579.x / max(_1579.w, 9.9999997473787516355514526367188e-05)) * _1584;
            highp vec4 _1586 = _1544;
            _1586.x = _1585;
            highp vec4 _1590 = textureLod(uSampler, _1575, 0.0);
            highp float _1595 = (_1590.z / max(_1590.w, 9.9999997473787516355514526367188e-05)) * _1584;
            _1586.z = _1595;
            highp vec4 _1623;
            if (_1546)
            {
                highp vec4 _1605 = textureLod(uTex1, _1573, 0.0);
                highp vec4 _1612 = _1554;
                _1612.x = (_1605.x / max(_1605.w, 9.9999997473787516355514526367188e-05)) * _1554.w;
                highp vec4 _1616 = textureLod(uTex1, _1575, 0.0);
                _1612.z = (_1616.z / max(_1616.w, 9.9999997473787516355514526367188e-05)) * _1554.w;
                _1623 = _1612;
            }
            else
            {
                highp vec4 _1600 = _1554;
                _1600.x = _1585;
                _1600.z = _1595;
                _1623 = _1600;
            }
            _1624 = _1623;
            _1625 = _1586;
        }
        else
        {
            _1624 = _1554;
            _1625 = _1544;
        }
        bool _1627 = uData[4].x > 1.5;
        highp float _1641;
        if (_1627)
        {
            _1641 = uData[3].w;
        }
        else
        {
            highp float _1639;
            if ((uData[6].x - 2.0 * trunc(uData[6].x / 2.0)) > 0.5)
            {
                _1639 = 1.0;
            }
            else
            {
                _1639 = _1625.w;
            }
            _1641 = _1639;
        }
        highp vec4 _1650 = vec4(_1625.xyz / vec3(max(_1625.w, 9.9999997473787516355514526367188e-05)), 1.0);
        highp vec4 _1659 = vec4(_1624.xyz / vec3(max(_1624.w, 9.9999997473787516355514526367188e-05)), 1.0);
        highp float _1666;
        if (_1627)
        {
            _1666 = 1.0;
        }
        else
        {
            _1666 = (uData[4].z > 0.5) ? uData[4].x : 0.0;
        }
        bool _1670;
        if (_145)
        {
            _1670 = !_1627;
        }
        else
        {
            _1670 = false;
        }
        highp float _1679;
        if (_1670)
        {
            _1679 = _1666 * (1.0 - ((_1538 * _1538) * (1.0 - smoothstep(0.800000011920928955078125, 1.0, _1666))));
        }
        else
        {
            _1679 = _1666;
        }
        highp float _1682 = 1.0 - _1679;
        highp float _1690;
        if (_145)
        {
            _1690 = _1538;
        }
        else
        {
            _1690 = _1498 * _1498;
        }
        highp float _1693 = clamp(((uData[2].y * _1504) * _1690) * _1682, 0.0, 1.0);
        highp vec4 _1699 = ((_1659 * _1693) + ((mix(_1659, _1650, vec4(clamp(_1478.x, 0.0, 1.0))) * _1682) * (1.0 - _1693))) + (uData[3] * _1679);
        highp vec4 _1742;
        if (_1627)
        {
            _1742 = vec4(uData[3].xyz / vec3(max(uData[3].w, 9.9999997473787516355514526367188e-05)), 1.0);
        }
        else
        {
            highp vec4 _1706 = _1699 + (_1650 * (1.0 - _1699.w));
            highp vec4 _1732;
            if (uData[7].w < 1.0)
            {
                highp vec3 _1711 = _1706.xyz;
                highp float _1712 = dot(_1711, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875));
                highp float _1713 = 0.60000002384185791015625 * uData[7].w;
                highp float _1715 = max(uData[7].w - _1713, 9.9999997473787516355514526367188e-05);
                highp float _1727;
                if (_1712 <= _1713)
                {
                    _1727 = _1712;
                }
                else
                {
                    _1727 = _1713 + (_1715 * (1.0 - exp((-(_1712 - _1713)) / _1715)));
                }
                highp vec3 _1730 = _1711 * (_1727 / max(_1712, 9.9999997473787516355514526367188e-05));
                _1732 = vec4(_1730.x, _1730.y, _1730.z, _1706.w);
            }
            else
            {
                _1732 = _1706;
            }
            _1742 = _1732;
        }
        highp float _1745 = dot(_1487, uData[9].xy);
        highp float _1746 = max(_1745, 0.0);
        highp float _1748 = max(-_1745, 0.0);
        highp float _1749 = abs(_1745);
        bool _1753;
        if (_145)
        {
            _1753 = uData[6].z > 0.0;
        }
        else
        {
            _1753 = false;
        }
        bool _1755 = uData[10].x > 0.0;
        highp float _1783;
        if (_1755)
        {
            _1783 = 0.0;
        }
        else
        {
            highp float _1782;
            if (_1753)
            {
                _1782 = (uData[6].z * (1.0 - smoothstep(0.20000000298023223876953125, 0.699999988079071044921875, _1749))) * exp((-max(0.0, -_1186)) / (uData[2].z * 2.5));
            }
            else
            {
                highp float _1767;
                if (_1189)
                {
                    _1767 = 0.699999988079071044921875;
                }
                else
                {
                    _1767 = uData[2].z * 0.625;
                }
                _1782 = uData[8].x * (1.0 - smoothstep(0.0, _1767, -_1186));
            }
            _1783 = _1782;
        }
        highp float _1793;
        if (_145)
        {
            _1793 = max((uData[5].w * _1538) * _1538, _1783) * min(_1504, 1.0);
        }
        else
        {
            _1793 = 0.0;
        }
        highp float _1796 = _1641 * (1.0 - _1793);
        highp vec4 _1802 = vec4(_1742.xyz * _1796, _1796 + _1793);
        highp float _1824;
        if (_145)
        {
            highp float _1823;
            if (_1753)
            {
                _1823 = uData[6].z * max(smoothstep(0.75, 1.0, _1749), max(_1492.x, _1492.y));
            }
            else
            {
                _1823 = 0.25;
            }
            _1824 = _1823;
        }
        else
        {
            _1824 = (0.449999988079071044921875 * ((_1746 * sqrt(_1746)) + ((0.75 * _1748) * sqrt(_1748)))) + 0.0599999986588954925537109375;
        }
        highp float _1860;
        if (_1753)
        {
            _1860 = exp((-max(0.0, -_1186)) / _1188);
        }
        else
        {
            highp float _1854;
            if (_145)
            {
                highp float _1853;
                if (_1189)
                {
                    highp float _1848 = -_1186;
                    _1853 = smoothstep(0.0, 0.89999997615814208984375, _1848) * (1.0 - smoothstep(1.5, 2.400000095367431640625, _1848));
                }
                else
                {
                    highp float _1841 = -_1186;
                    _1853 = smoothstep(uData[2].z * 0.3125, uData[2].z * 0.625, _1841) * (1.0 - smoothstep(uData[2].z * 1.5, uData[2].z * 2.0, _1841));
                }
                _1854 = _1853;
            }
            else
            {
                _1854 = exp((-max(0.0, -_1186)) / uData[2].z);
            }
            _1860 = _1854;
        }
        highp float _1872;
        if (_1755)
        {
            _1872 = 0.0;
        }
        else
        {
            highp float _1870;
            if (_145)
            {
                _1870 = 0.0;
            }
            else
            {
                _1870 = (0.039999999105930328369140625 * exp(_1495 / uData[1].w)) * _1746;
            }
            _1872 = (_1860 * _1824) + _1870;
        }
        highp vec2 _1873 = mix(_1139, _1138, _1488);
        highp float _1877 = _1873.y;
        highp float _1883 = clamp((vTextureCoord.y - (_1873.x - _1877)) / max(2.0 * _1877, 9.9999997473787516355514526367188e-05), 0.0, 1.0);
        highp float _1901;
        if (uData[4].z > 0.5)
        {
            _1901 = uData[4].y + ((uData[7].x + ((uData[7].y - uData[7].x) * _1883)) + (uData[7].z * (1.0 - smoothstep(0.0, 0.37999999523162841796875, _1883))));
        }
        else
        {
            _1901 = 0.0;
        }
        highp vec3 _1911 = _1802.xyz + vec3(clamp((_1901 + _1478.z) + ((_1504 * uData[2].w) * _1872), 0.0, 1.0));
        highp vec4 _1983;
        if (_1755)
        {
            highp vec2 _1921;
            if (dot(_1487, _1487) > 9.9999999392252902907785028219223e-09)
            {
                _1921 = normalize(_1487);
            }
            else
            {
                _1921 = vec2(0.0);
            }
            highp float _1922 = dot(_1921, uData[9].xy);
            highp float _1924 = mix(8.0, 1.0, uData[9].z);
            highp float _1932 = pow(max(_1922, 0.0), _1924) + (uData[9].w * pow(max(-_1922, 0.0), _1924));
            highp float _1933 = min(_1504, 1.0);
            highp float _1940 = -_1186;
            highp float _1942 = smoothstep(-0.5, 0.5, _1940);
            highp float _1944 = -max(0.0, _1940);
            highp vec3 _1981 = (_1911.xyz * (1.0 - (((uData[10].z * (1.0 - abs(_1922))) * (_1942 * exp(_1944 / max(uData[2].z * 2.5, 0.001000000047497451305389404296875)))) * _1933))) + vec3(_1933 * (((uData[10].x * max(_1932, max(_1492.x, uData[9].w * _1492.y))) * (_1942 * exp(_1944 / max(uData[8].y, 0.001000000047497451305389404296875)))) + ((uData[10].y * _1932) * (smoothstep(uData[8].y - 0.5, uData[8].y + 0.5, _1940) * exp((-max(0.0, _1940 - uData[8].y)) / max(uData[8].z, 0.001000000047497451305389404296875))))));
            _1983 = vec4(_1981.x, _1981.y, _1981.z, _1802.w);
        }
        else
        {
            _1983 = vec4(_1911.x, _1911.y, _1911.z, _1802.w);
        }
        highp vec4 _1984 = clamp(_1983, vec4(0.0), vec4(1.0));
        highp float _1991 = max(_1984.w, max(_1984.x, max(_1984.y, _1984.z)));
        highp vec4 _1992 = _1984;
        _1992.w = _1991;
        highp vec3 _2003 = _1992.xyz + vec3(((fract(52.98291778564453125 * fract(dot(vTextureCoord, vec2(0.067110560834407806396484375, 0.005837149918079376220703125)))) - 0.5) * uData[5].x) * _1991);
        _2007 = clamp(vec4(_2003.x, _2003.y, _2003.z, _1992.w), vec4(0.0), vec4(1.0)) * _1194;
        break;
    } while(false);
    out_var_SV_Target0 = _2007;
}

