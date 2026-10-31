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
    highp vec4 _1712;
    do
    {
        int _110 = int((vColor.y * 255.0) + 0.5);
        int _115 = int((vColor.z * 255.0) + 0.5);
        bool _139 = uData[5].y > 0.0;
        highp vec2 _141;
        highp float _144;
        highp vec2 _146;
        highp vec2 _148;
        highp vec4 _150;
        highp vec2 _152;
        highp float _154;
        highp float _156;
        highp vec2 _158;
        highp vec2 _160;
        highp vec4 _162;
        highp float _164;
        highp float _166;
        highp float _168;
        _141 = vec2(0.0, 1.0);
        _144 = 1000000000.0;
        _146 = vec2(0.0);
        _148 = vec2(0.0);
        _150 = vec4(0.0);
        _152 = vec2(0.0);
        _154 = 1000000000.0;
        _156 = 1000000000.0;
        _158 = vec2(0.0);
        _160 = vec2(0.0, 1.0);
        _162 = vec4(0.0);
        _164 = 1000000000.0;
        _166 = 1000000000.0;
        _168 = 1000000000.0;
        highp vec2 _153;
        highp float _157;
        highp vec2 _159;
        highp vec4 _163;
        highp float _167;
        highp float _169;
        highp vec2 _142;
        highp float _145;
        highp vec2 _147;
        highp vec2 _149;
        highp vec4 _151;
        highp float _155;
        highp vec2 _161;
        highp float _165;
        int _170 = _110;
        for (;;)
        {
            bool _179;
            if (_170 < (_110 + _115))
            {
                _179 = _170 < 16;
            }
            else
            {
                _179 = false;
            }
            if (_179)
            {
                int _181 = 3 * _170;
                int _188 = _181 + 13;
                bool _196;
                if (uData[_188 * 1 + 0].w >= (-0.5))
                {
                    _196 = uData[_188 * 1 + 0].w > 3.5;
                }
                else
                {
                    _196 = true;
                }
                highp vec4 _206;
                highp vec4 _207;
                highp vec4 _208;
                if (_196)
                {
                    highp vec4 _204 = uData[58];
                    _204.z = 0.0;
                    _206 = _204;
                    _207 = uData[56];
                    _208 = uData[57];
                }
                else
                {
                    _206 = uData[_188 * 1 + 0];
                    _207 = uData[(11 + _181) * 1 + 0];
                    _208 = uData[(_181 + 12) * 1 + 0];
                }
                highp float _211 = min(_207.z, _207.w);
                highp vec4 _213 = min(_208, vec4(_211));
                highp vec2 _498;
                highp float _499;
                if (_196)
                {
                    highp vec4 _288 = min(uData[57], vec4(min(uData[56].z, uData[56].w)));
                    int _291 = int(uData[58].z);
                    highp vec2 _293 = vTextureCoord - uData[56].xy;
                    highp float _295 = _293.x;
                    highp float _316;
                    if (_295 > 0.0)
                    {
                        highp float _315;
                        if (_293.y > 0.0)
                        {
                            _315 = _288.z;
                        }
                        else
                        {
                            _315 = _288.y;
                        }
                        _316 = _315;
                    }
                    else
                    {
                        highp float _307;
                        if (_293.y > 0.0)
                        {
                            _307 = _288.w;
                        }
                        else
                        {
                            _307 = _288.x;
                        }
                        _316 = _307;
                    }
                    highp vec2 _320 = (abs(_293) - uData[56].zw) + vec2(_316);
                    highp float _322 = (_295 < 0.0) ? (-1.0) : 1.0;
                    highp float _325 = (_293.y < 0.0) ? (-1.0) : 1.0;
                    highp float _327 = _320.x;
                    bool _333;
                    if (_327 > 0.0)
                    {
                        _333 = _320.y > 0.0;
                    }
                    else
                    {
                        _333 = false;
                    }
                    highp vec2 _347;
                    if (_333)
                    {
                        _347 = normalize(_320) * vec2(_322, _325);
                    }
                    else
                    {
                        highp vec2 _344;
                        if (_327 > _320.y)
                        {
                            _344 = vec2(_322, 0.0);
                        }
                        else
                        {
                            _344 = vec2(0.0, _325);
                        }
                        _347 = _344;
                    }
                    highp vec2 _356;
                    highp float _359;
                    _356 = _347;
                    _359 = (min(max(_327, _320.y), 0.0) + length(max(_320, vec2(0.0)))) - _316;
                    highp vec2 _357;
                    highp float _360;
                    int _361 = 0;
                    for (;;)
                    {
                        bool _369;
                        if (_361 < _291)
                        {
                            _369 = _361 < 4;
                        }
                        else
                        {
                            _369 = false;
                        }
                        if (_369)
                        {
                            int _371 = 14 - _361;
                            int _372 = 3 * _371;
                            int _373 = 11 + _372;
                            int _376 = _372 + 12;
                            if (uData[_376 * 1 + 0].x == 0.0)
                            {
                                _357 = _356;
                                _360 = _359;
                                int _362 = _361 + 1;
                                _356 = _357;
                                _359 = _360;
                                _361 = _362;
                                continue;
                            }
                            highp float _385 = clamp(uData[_376 * 1 + 0].x / uData[_376 * 1 + 0].y, 0.0, 1.0);
                            bool _387 = uData[_373 * 1 + 0].x < 0.5;
                            highp float _395;
                            if (_387)
                            {
                                _395 = vTextureCoord.y;
                            }
                            else
                            {
                                _395 = vTextureCoord.x;
                            }
                            highp float _403;
                            if (_387)
                            {
                                _403 = vTextureCoord.x;
                            }
                            else
                            {
                                _403 = vTextureCoord.y;
                            }
                            highp float _405 = _403 - uData[_373 * 1 + 0].y;
                            highp float _406 = uData[_376 * 1 + 0].x * 0.5;
                            highp float _409 = uData[_373 * 1 + 0].w - uData[_373 * 1 + 0].z;
                            highp float _410 = smoothstep(0.0, 0.60000002384185791015625, _385);
                            highp float _439;
                            highp float _440;
                            if (uData[_376 * 1 + 0].w > 2.5)
                            {
                                highp float _430 = _395 - ((uData[_373 * 1 + 0].z + uData[_373 * 1 + 0].w) * 0.5);
                                _439 = (_430 < 0.0) ? 1.0 : (-1.0);
                                _440 = max(((_409 * 0.5) * (1.0 - _410)) - abs(_430), 0.0);
                            }
                            else
                            {
                                bool _416 = uData[_376 * 1 + 0].w < 1.5;
                                highp float _422;
                                if (_416)
                                {
                                    _422 = _395 - uData[_373 * 1 + 0].z;
                                }
                                else
                                {
                                    _422 = uData[_373 * 1 + 0].w - _395;
                                }
                                _439 = _416 ? 1.0 : (-1.0);
                                _440 = max(_422 - ((_409 - _406) * _410), 0.0);
                            }
                            highp float _442 = length(vec2(_405, _440));
                            highp float _443 = _442 - _406;
                            highp vec2 _458;
                            if (_442 > 0.0)
                            {
                                highp vec2 _452 = vec2(-_405, (-_440) * _439) / vec2(_442);
                                highp vec2 _457;
                                if (uData[_373 * 1 + 0].x > 0.5)
                                {
                                    _457 = _452.yx;
                                }
                                else
                                {
                                    _457 = _452;
                                }
                                _458 = _457;
                            }
                            else
                            {
                                _458 = vec2(0.0);
                            }
                            highp float _460 = uData[_376 * 1 + 0].z * _385;
                            highp vec2 _464 = max(vec2(_460 + _359, _460 - _443), vec2(0.0));
                            highp float _465 = length(_464);
                            bool _470;
                            if (_460 > 0.0)
                            {
                                _470 = _465 > 0.0;
                            }
                            else
                            {
                                _470 = false;
                            }
                            highp vec2 _485;
                            if (_470)
                            {
                                _485 = ((_356 * _464.x) + (_458 * _464.y)) / vec2(_465);
                            }
                            else
                            {
                                bvec2 _476 = bvec2((-_443) > _359);
                                _485 = vec2(_476.x ? _458.x : _356.x, _476.y ? _458.y : _356.y);
                            }
                            highp float _486 = -_443;
                            highp float _497;
                            do
                            {
                                if (_460 == 0.0)
                                {
                                    _497 = max(_359, _486);
                                    break;
                                }
                                _497 = min(-_460, max(_359, _486)) + _465;
                                break;
                            } while(false);
                            _357 = _485;
                            _360 = _497;
                            int _362 = _361 + 1;
                            _356 = _357;
                            _359 = _360;
                            _361 = _362;
                            continue;
                        }
                        else
                        {
                            break;
                        }
                    }
                    _498 = _356;
                    _499 = _359;
                }
                else
                {
                    highp vec2 _218 = vTextureCoord - _207.xy;
                    highp float _220 = _218.x;
                    highp float _241;
                    if (_220 > 0.0)
                    {
                        highp float _240;
                        if (_218.y > 0.0)
                        {
                            _240 = _213.z;
                        }
                        else
                        {
                            _240 = _213.y;
                        }
                        _241 = _240;
                    }
                    else
                    {
                        highp float _232;
                        if (_218.y > 0.0)
                        {
                            _232 = _213.w;
                        }
                        else
                        {
                            _232 = _213.x;
                        }
                        _241 = _232;
                    }
                    highp vec2 _245 = (abs(_218) - _207.zw) + vec2(_241);
                    highp float _247 = (_220 < 0.0) ? (-1.0) : 1.0;
                    highp float _250 = (_218.y < 0.0) ? (-1.0) : 1.0;
                    highp float _252 = _245.x;
                    bool _258;
                    if (_252 > 0.0)
                    {
                        _258 = _245.y > 0.0;
                    }
                    else
                    {
                        _258 = false;
                    }
                    highp vec2 _272;
                    if (_258)
                    {
                        _272 = normalize(_245) * vec2(_247, _250);
                    }
                    else
                    {
                        highp vec2 _269;
                        if (_252 > _245.y)
                        {
                            _269 = vec2(_247, 0.0);
                        }
                        else
                        {
                            _269 = vec2(0.0, _250);
                        }
                        _272 = _269;
                    }
                    _498 = _272;
                    _499 = (min(max(_252, _245.y), 0.0) + length(max(_245, vec2(0.0)))) - _241;
                }
                highp vec2 _647;
                if (uData[10].w > 0.0)
                {
                    highp float _508 = (uData[9].x < 0.0) ? (-1.0) : 1.0;
                    highp float _511 = (uData[9].y < 0.0) ? (-1.0) : 1.0;
                    highp float _531;
                    if (_508 < 0.0)
                    {
                        highp float _530;
                        if (_511 < 0.0)
                        {
                            _530 = _213.x;
                        }
                        else
                        {
                            _530 = _213.w;
                        }
                        _531 = _530;
                    }
                    else
                    {
                        highp float _523;
                        if (_511 < 0.0)
                        {
                            _523 = _213.y;
                        }
                        else
                        {
                            _523 = _213.z;
                        }
                        _531 = _523;
                    }
                    highp vec2 _535 = max(_207.zw - vec2(_531), vec2(0.0));
                    highp vec2 _540 = (_207.xy + (vec2(_508, _511) * _535)) + (uData[9].xy * _531);
                    highp vec2 _555;
                    if (abs(uData[9].x) < 0.001000000047497451305389404296875)
                    {
                        highp float _548 = _535.x;
                        highp vec2 _554 = _540;
                        _554.x = clamp(vTextureCoord.x, _207.x - _548, _207.x + _548) + (_531 * uData[9].x);
                        _555 = _554;
                    }
                    else
                    {
                        _555 = _540;
                    }
                    highp vec2 _570;
                    if (abs(uData[9].y) < 0.001000000047497451305389404296875)
                    {
                        highp float _563 = _535.y;
                        highp vec2 _569 = _555;
                        _569.y = clamp(vTextureCoord.y, _207.y - _563, _207.y + _563) + (_531 * uData[9].y);
                        _570 = _569;
                    }
                    else
                    {
                        _570 = _555;
                    }
                    highp float _573 = max(uData[10].w - max(uData[8].w, 1.0), 0.0);
                    highp vec2 _578 = -uData[9].xy;
                    highp float _579 = _578.x;
                    highp float _581 = (_579 < 0.0) ? (-1.0) : 1.0;
                    highp float _582 = _578.y;
                    highp float _584 = (_582 < 0.0) ? (-1.0) : 1.0;
                    highp float _604;
                    if (_581 < 0.0)
                    {
                        highp float _603;
                        if (_584 < 0.0)
                        {
                            _603 = _213.x;
                        }
                        else
                        {
                            _603 = _213.w;
                        }
                        _604 = _603;
                    }
                    else
                    {
                        highp float _596;
                        if (_584 < 0.0)
                        {
                            _596 = _213.y;
                        }
                        else
                        {
                            _596 = _213.z;
                        }
                        _604 = _596;
                    }
                    highp vec2 _607 = max(_207.zw - vec2(_604), vec2(0.0));
                    highp vec2 _611 = (_207.xy + (vec2(_581, _584) * _607)) + (_578 * _604);
                    highp vec2 _626;
                    if (abs(_579) < 0.001000000047497451305389404296875)
                    {
                        highp float _619 = _607.x;
                        highp vec2 _625 = _611;
                        _625.x = clamp(vTextureCoord.x, _207.x - _619, _207.x + _619) + (_604 * _579);
                        _626 = _625;
                    }
                    else
                    {
                        _626 = _611;
                    }
                    highp vec2 _641;
                    if (abs(_582) < 0.001000000047497451305389404296875)
                    {
                        highp float _634 = _607.y;
                        highp vec2 _640 = _626;
                        _640.y = clamp(vTextureCoord.y, _207.y - _634, _207.y + _634) + (_604 * _582);
                        _641 = _640;
                    }
                    else
                    {
                        _641 = _626;
                    }
                    _647 = vec2(1.0 - smoothstep(_573, uData[10].w, length(vTextureCoord - _570)), 1.0 - smoothstep(_573, uData[10].w, length(vTextureCoord - _641)));
                }
                else
                {
                    _647 = vec2(0.0);
                }
                bool _648 = _499 < _166;
                if (_648)
                {
                    _142 = _160;
                    _145 = _168;
                    _147 = _158;
                    _151 = _162;
                    _161 = _207.yw;
                    _165 = _166;
                }
                else
                {
                    bool _652 = _499 < _164;
                    highp vec2 _656;
                    if (_652)
                    {
                        _656 = _207.yw;
                    }
                    else
                    {
                        _656 = _141;
                    }
                    bvec2 _658 = bvec2(_652);
                    bvec4 _660 = bvec4(_652);
                    _142 = _656;
                    _145 = _652 ? _211 : _144;
                    _147 = vec2(_658.x ? _647.x : _146.x, _658.y ? _647.y : _146.y);
                    _151 = vec4(_660.x ? _206.x : _150.x, _660.y ? _206.y : _150.y, _660.z ? _206.z : _150.z, _660.w ? _206.w : _150.w);
                    _161 = _160;
                    _165 = _652 ? _499 : _164;
                }
                bvec2 _664 = bvec2(_648);
                _159 = vec2(_664.x ? _647.x : _158.x, _664.y ? _647.y : _158.y);
                bvec4 _665 = bvec4(_648);
                _163 = vec4(_665.x ? _206.x : _162.x, _665.y ? _206.y : _162.y, _665.z ? _206.z : _162.z, _665.w ? _206.w : _162.w);
                _167 = _648 ? _499 : _166;
                _169 = _648 ? _211 : _168;
                highp vec2 _978;
                highp float _979;
                if (_196)
                {
                    highp vec4 _724 = min(uData[57], vec4(min(uData[56].z, uData[56].w)));
                    int _727 = int(uData[58].z);
                    highp vec2 _833;
                    highp float _834;
                    if (uData[1].y > 0.0)
                    {
                        highp float _799 = (vTextureCoord.x - uData[56].x) + uData[56].z;
                        highp float _801 = (uData[56].x + uData[56].z) - vTextureCoord.x;
                        highp float _806 = (vTextureCoord.y - uData[56].y) + uData[56].w;
                        highp float _808 = (uData[56].y + uData[56].w) - vTextureCoord.y;
                        highp float _812 = min(min(_799, _801), min(_806, _808));
                        highp vec4 _817 = exp((vec4(_812) - vec4(_799, _801, _806, _808)) / vec4(uData[1].y));
                        highp float _818 = _817.x;
                        highp float _819 = _817.y;
                        highp float _821 = _817.z;
                        highp float _823 = _817.w;
                        highp float _824 = ((_818 + _819) + _821) + _823;
                        _833 = vec2(_819 - _818, _823 - _821) / vec2(_824);
                        _834 = (uData[1].y * log(_824)) - _812;
                    }
                    else
                    {
                        highp vec2 _733 = vTextureCoord - uData[56].xy;
                        highp float _735 = _733.x;
                        highp float _756;
                        if (_735 > 0.0)
                        {
                            highp float _755;
                            if (_733.y > 0.0)
                            {
                                _755 = _724.z;
                            }
                            else
                            {
                                _755 = _724.y;
                            }
                            _756 = _755;
                        }
                        else
                        {
                            highp float _747;
                            if (_733.y > 0.0)
                            {
                                _747 = _724.w;
                            }
                            else
                            {
                                _747 = _724.x;
                            }
                            _756 = _747;
                        }
                        highp vec2 _760 = (abs(_733) - uData[56].zw) + vec2(_756);
                        highp float _762 = (_735 < 0.0) ? (-1.0) : 1.0;
                        highp float _765 = (_733.y < 0.0) ? (-1.0) : 1.0;
                        highp float _767 = _760.x;
                        bool _773;
                        if (_767 > 0.0)
                        {
                            _773 = _760.y > 0.0;
                        }
                        else
                        {
                            _773 = false;
                        }
                        highp vec2 _787;
                        if (_773)
                        {
                            _787 = normalize(_760) * vec2(_762, _765);
                        }
                        else
                        {
                            highp vec2 _784;
                            if (_767 > _760.y)
                            {
                                _784 = vec2(_762, 0.0);
                            }
                            else
                            {
                                _784 = vec2(0.0, _765);
                            }
                            _787 = _784;
                        }
                        _833 = _787;
                        _834 = (min(max(_767, _760.y), 0.0) + length(max(_760, vec2(0.0)))) - _756;
                    }
                    highp vec2 _836;
                    highp float _839;
                    _836 = _833;
                    _839 = _834;
                    highp vec2 _837;
                    highp float _840;
                    int _841 = 0;
                    for (;;)
                    {
                        bool _849;
                        if (_841 < _727)
                        {
                            _849 = _841 < 4;
                        }
                        else
                        {
                            _849 = false;
                        }
                        if (_849)
                        {
                            int _851 = 14 - _841;
                            int _852 = 3 * _851;
                            int _853 = 11 + _852;
                            int _856 = _852 + 12;
                            if (uData[_856 * 1 + 0].x == 0.0)
                            {
                                _837 = _836;
                                _840 = _839;
                                int _842 = _841 + 1;
                                _836 = _837;
                                _839 = _840;
                                _841 = _842;
                                continue;
                            }
                            highp float _865 = clamp(uData[_856 * 1 + 0].x / uData[_856 * 1 + 0].y, 0.0, 1.0);
                            bool _867 = uData[_853 * 1 + 0].x < 0.5;
                            highp float _875;
                            if (_867)
                            {
                                _875 = vTextureCoord.y;
                            }
                            else
                            {
                                _875 = vTextureCoord.x;
                            }
                            highp float _883;
                            if (_867)
                            {
                                _883 = vTextureCoord.x;
                            }
                            else
                            {
                                _883 = vTextureCoord.y;
                            }
                            highp float _885 = _883 - uData[_853 * 1 + 0].y;
                            highp float _886 = uData[_856 * 1 + 0].x * 0.5;
                            highp float _889 = uData[_853 * 1 + 0].w - uData[_853 * 1 + 0].z;
                            highp float _890 = smoothstep(0.0, 0.60000002384185791015625, _865);
                            highp float _919;
                            highp float _920;
                            if (uData[_856 * 1 + 0].w > 2.5)
                            {
                                highp float _910 = _875 - ((uData[_853 * 1 + 0].z + uData[_853 * 1 + 0].w) * 0.5);
                                _919 = (_910 < 0.0) ? 1.0 : (-1.0);
                                _920 = max(((_889 * 0.5) * (1.0 - _890)) - abs(_910), 0.0);
                            }
                            else
                            {
                                bool _896 = uData[_856 * 1 + 0].w < 1.5;
                                highp float _902;
                                if (_896)
                                {
                                    _902 = _875 - uData[_853 * 1 + 0].z;
                                }
                                else
                                {
                                    _902 = uData[_853 * 1 + 0].w - _875;
                                }
                                _919 = _896 ? 1.0 : (-1.0);
                                _920 = max(_902 - ((_889 - _886) * _890), 0.0);
                            }
                            highp float _922 = length(vec2(_885, _920));
                            highp float _923 = _922 - _886;
                            highp vec2 _938;
                            if (_922 > 0.0)
                            {
                                highp vec2 _932 = vec2(-_885, (-_920) * _919) / vec2(_922);
                                highp vec2 _937;
                                if (uData[_853 * 1 + 0].x > 0.5)
                                {
                                    _937 = _932.yx;
                                }
                                else
                                {
                                    _937 = _932;
                                }
                                _938 = _937;
                            }
                            else
                            {
                                _938 = vec2(0.0);
                            }
                            highp float _940 = uData[_856 * 1 + 0].z * _865;
                            highp vec2 _944 = max(vec2(_940 + _839, _940 - _923), vec2(0.0));
                            highp float _945 = length(_944);
                            bool _950;
                            if (_940 > 0.0)
                            {
                                _950 = _945 > 0.0;
                            }
                            else
                            {
                                _950 = false;
                            }
                            highp vec2 _965;
                            if (_950)
                            {
                                _965 = ((_836 * _944.x) + (_938 * _944.y)) / vec2(_945);
                            }
                            else
                            {
                                bvec2 _956 = bvec2((-_923) > _839);
                                _965 = vec2(_956.x ? _938.x : _836.x, _956.y ? _938.y : _836.y);
                            }
                            highp float _966 = -_923;
                            highp float _977;
                            do
                            {
                                if (_940 == 0.0)
                                {
                                    _977 = max(_839, _966);
                                    break;
                                }
                                _977 = min(-_940, max(_839, _966)) + _945;
                                break;
                            } while(false);
                            _837 = _965;
                            _840 = _977;
                            int _842 = _841 + 1;
                            _836 = _837;
                            _839 = _840;
                            _841 = _842;
                            continue;
                        }
                        else
                        {
                            break;
                        }
                    }
                    _978 = _836;
                    _979 = _839;
                }
                else
                {
                    highp vec2 _713;
                    highp float _714;
                    if (_206.w < 0.5)
                    {
                        highp float _679 = (vTextureCoord.x - _207.x) + _207.z;
                        highp float _681 = (_207.x + _207.z) - vTextureCoord.x;
                        highp float _686 = (vTextureCoord.y - _207.y) + _207.w;
                        highp float _688 = (_207.y + _207.w) - vTextureCoord.y;
                        highp float _692 = min(min(_679, _681), min(_686, _688));
                        highp vec4 _697 = exp((vec4(_692) - vec4(_679, _681, _686, _688)) / vec4(uData[1].y));
                        highp float _698 = _697.x;
                        highp float _699 = _697.y;
                        highp float _701 = _697.z;
                        highp float _703 = _697.w;
                        highp float _704 = ((_698 + _699) + _701) + _703;
                        _713 = vec2(_699 - _698, _703 - _701) / vec2(_704);
                        _714 = (uData[1].y * log(_704)) - _692;
                    }
                    else
                    {
                        _713 = _498;
                        _714 = _499;
                    }
                    _978 = _713;
                    _979 = _714;
                }
                bool _980 = _979 < _156;
                if (_980)
                {
                    _149 = _152;
                    _155 = _156;
                }
                else
                {
                    bool _984 = _979 < _154;
                    bvec2 _985 = bvec2(_984);
                    _149 = vec2(_985.x ? _978.x : _148.x, _985.y ? _978.y : _148.y);
                    _155 = _984 ? _979 : _154;
                }
                bvec2 _988 = bvec2(_980);
                _153 = vec2(_988.x ? _978.x : _152.x, _988.y ? _978.y : _152.y);
                _157 = _980 ? _979 : _156;
                _141 = _142;
                _144 = _145;
                _146 = _147;
                _148 = _149;
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
                _170++;
                continue;
            }
            else
            {
                break;
            }
        }
        bool _998;
        if (uData[58].w > 2.5)
        {
            _998 = uData[58].w < 3.5;
        }
        else
        {
            _998 = false;
        }
        bool _999 = uData[58].w > 1.5;
        bool _1003;
        if (_999)
        {
            _1003 = uData[58].w < 3.5;
        }
        else
        {
            _1003 = false;
        }
        highp float _1076;
        highp vec2 _1077;
        if (_1003)
        {
            highp vec2 _1009 = vTextureCoord - uData[56].xy;
            highp vec4 _1015 = min(uData[57], vec4(min(uData[56].z, uData[56].w)));
            highp float _1016 = _1009.x;
            highp float _1037;
            if (_1016 > 0.0)
            {
                highp float _1036;
                if (_1009.y > 0.0)
                {
                    _1036 = _1015.z;
                }
                else
                {
                    _1036 = _1015.y;
                }
                _1037 = _1036;
            }
            else
            {
                highp float _1028;
                if (_1009.y > 0.0)
                {
                    _1028 = _1015.w;
                }
                else
                {
                    _1028 = _1015.x;
                }
                _1037 = _1028;
            }
            highp vec2 _1041 = (abs(_1009) - uData[56].zw) + vec2(_1037);
            highp float _1043 = (_1016 < 0.0) ? (-1.0) : 1.0;
            highp float _1046 = (_1009.y < 0.0) ? (-1.0) : 1.0;
            highp float _1048 = _1041.x;
            bool _1054;
            if (_1048 > 0.0)
            {
                _1054 = _1041.y > 0.0;
            }
            else
            {
                _1054 = false;
            }
            highp vec2 _1068;
            if (_1054)
            {
                _1068 = normalize(_1041) * vec2(_1043, _1046);
            }
            else
            {
                highp vec2 _1065;
                if (_1048 > _1041.y)
                {
                    _1065 = vec2(_1043, 0.0);
                }
                else
                {
                    _1065 = vec2(0.0, _1046);
                }
                _1068 = _1065;
            }
            _1076 = (min(max(_1048, _1041.y), 0.0) + length(max(_1041, vec2(0.0)))) - _1037;
            _1077 = _1068;
        }
        else
        {
            _1076 = -1000000000.0;
            _1077 = vec2(0.0);
        }
        bool _1081;
        if (_999)
        {
            _1081 = uData[58].w < 3.5;
        }
        else
        {
            _1081 = false;
        }
        bool _1085;
        if (_1081)
        {
            _1085 = !_998;
        }
        else
        {
            _1085 = false;
        }
        highp vec2 _1130;
        highp vec2 _1131;
        highp float _1132;
        highp vec2 _1133;
        highp vec2 _1134;
        highp vec2 _1135;
        highp vec2 _1136;
        highp vec4 _1137;
        highp vec4 _1138;
        highp float _1139;
        highp float _1140;
        highp float _1141;
        highp float _1142;
        if (_1085)
        {
            highp float _1088 = 1.0 - _1076;
            bool _1089 = _1088 < _166;
            highp vec2 _1105;
            highp vec2 _1106;
            highp float _1107;
            highp vec2 _1108;
            highp vec4 _1109;
            highp float _1110;
            if (_1089)
            {
                _1105 = _160;
                _1106 = uData[56].yw;
                _1107 = _168;
                _1108 = _158;
                _1109 = _162;
                _1110 = _166;
            }
            else
            {
                bool _1093 = _1088 < _164;
                highp vec2 _1097;
                if (_1093)
                {
                    _1097 = uData[56].yw;
                }
                else
                {
                    _1097 = _141;
                }
                bvec2 _1099 = bvec2(_1093);
                bvec4 _1101 = bvec4(_1093);
                _1105 = _1097;
                _1106 = _160;
                _1107 = _1093 ? _168 : _144;
                _1108 = vec2(_1099.x ? vec2(0.0).x : _146.x, _1099.y ? vec2(0.0).y : _146.y);
                _1109 = vec4(_1101.x ? uData[58].x : _150.x, _1101.y ? uData[58].y : _150.y, _1101.z ? uData[58].z : _150.z, _1101.w ? uData[58].w : _150.w);
                _1110 = _1093 ? _1088 : _164;
            }
            bvec2 _1111 = bvec2(_1089);
            bvec4 _1113 = bvec4(_1089);
            highp vec2 _1116 = -_1077;
            bool _1117 = _1088 < _156;
            highp vec2 _1125;
            highp float _1126;
            if (_1117)
            {
                _1125 = _152;
                _1126 = _156;
            }
            else
            {
                bool _1121 = _1088 < _154;
                bvec2 _1122 = bvec2(_1121);
                _1125 = vec2(_1122.x ? _1116.x : _148.x, _1122.y ? _1116.y : _148.y);
                _1126 = _1121 ? _1088 : _154;
            }
            bvec2 _1127 = bvec2(_1117);
            _1130 = _1105;
            _1131 = _1106;
            _1132 = _1107;
            _1133 = _1108;
            _1134 = vec2(_1111.x ? vec2(0.0).x : _158.x, _1111.y ? vec2(0.0).y : _158.y);
            _1135 = _1125;
            _1136 = vec2(_1127.x ? _1116.x : _152.x, _1127.y ? _1116.y : _152.y);
            _1137 = _1109;
            _1138 = vec4(_1113.x ? uData[58].x : _162.x, _1113.y ? uData[58].y : _162.y, _1113.z ? uData[58].z : _162.z, _1113.w ? uData[58].w : _162.w);
            _1139 = _1126;
            _1140 = _1117 ? _1088 : _156;
            _1141 = _1110;
            _1142 = _1089 ? _1088 : _166;
        }
        else
        {
            _1130 = _141;
            _1131 = _160;
            _1132 = _144;
            _1133 = _146;
            _1134 = _158;
            _1135 = _148;
            _1136 = _152;
            _1137 = _150;
            _1138 = _162;
            _1139 = _154;
            _1140 = _156;
            _1141 = _164;
            _1142 = _166;
        }
        highp float _1144 = max(uData[1].x, 9.9999997473787516355514526367188e-05);
        highp float _1149 = max(_1144 - abs(_1142 - _1141), 0.0) / _1144;
        highp float _1150 = _1149 * _1149;
        highp float _1151 = _1150 * 0.5;
        highp float _1156;
        if (_1141 < _1142)
        {
            _1156 = 1.0 - _1151;
        }
        else
        {
            _1156 = _1151;
        }
        highp float _1160 = min(_1142, _1141) - ((_1150 * _1144) * 0.25);
        highp float _1165 = max(_1144 - abs(_1140 - _1139), 0.0) / _1144;
        highp float _1166 = _1165 * _1165;
        highp float _1167 = _1166 * 0.5;
        highp float _1172;
        if (_1139 < _1140)
        {
            _1172 = 1.0 - _1167;
        }
        else
        {
            _1172 = _1167;
        }
        highp float _1176 = min(_1140, _1139) - ((_1166 * _1144) * 0.25);
        highp float _1180;
        if (_998)
        {
            _1180 = max(_1160, _1076);
        }
        else
        {
            _1180 = _1160;
        }
        highp float _1183 = clamp(0.5 - max(_1180, _1076), 0.0, 1.0);
        if (_1183 <= 0.0)
        {
            discard;
        }
        if (vColor.x < 0.5)
        {
            _1712 = vec4(0.0, 0.0, 0.0, _1183);
            break;
        }
        highp vec4 _1194 = mix(_1138, _1137, vec4(_1156));
        highp vec2 _1196 = mix(_1136, _1135, vec2(_1172));
        bool _1200;
        if (_998)
        {
            _1200 = _1076 > _1176;
        }
        else
        {
            _1200 = false;
        }
        bvec2 _1202 = bvec2(_1200);
        highp vec2 _1203 = vec2(_1202.x ? _1077.x : _1196.x, _1202.y ? _1077.y : _1196.y);
        highp vec2 _1204 = vec2(_1156);
        highp vec2 _1208 = mix(_1134, _1133, _1204) * min(length(_1203), 1.0);
        highp float _1210 = max(0.0, -(_1200 ? _1076 : _1176));
        highp float _1211 = -_1210;
        highp float _1214 = exp(_1211 / uData[1].z);
        highp float _1220 = _1194.y;
        highp float _1254;
        highp float _1255;
        highp vec2 _1256;
        if (_139)
        {
            highp float _1238 = max(min(uData[5].y * mix(_168, _1132, _1156), uData[6].w), 1.0);
            highp float _1241 = clamp(1.0 - (_1210 / _1238), 0.0, 1.0);
            highp float _1246 = (((uData[5].z * _1238) * _1220) * _1241) * _1241;
            _1254 = _1241;
            _1255 = _1246;
            _1256 = clamp(((vTextureCoord - (_1203 * _1246)) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        else
        {
            _1254 = 0.0;
            _1255 = 0.0;
            _1256 = clamp(((vTextureCoord + (_1203 * ((uData[2].x * _1220) * _1214))) - uData[0].xy) * uData[0].zw, vec2(0.0), vec2(1.0));
        }
        highp vec4 _1260 = textureLod(uSampler, _1256, 0.0);
        bool _1262 = uData[4].w > 0.5;
        highp vec4 _1270;
        if (_1262)
        {
            _1270 = textureLod(uTex1, _1256, 0.0);
        }
        else
        {
            _1270 = _1260;
        }
        bool _1275;
        if (_139)
        {
            _1275 = uData[6].y > 0.0;
        }
        else
        {
            _1275 = false;
        }
        bool _1279;
        if (_1275)
        {
            _1279 = _1255 > 0.5;
        }
        else
        {
            _1279 = false;
        }
        highp vec4 _1340;
        highp vec4 _1341;
        if (_1279)
        {
            highp vec2 _1287 = (_1203 * ((_1255 * 0.039999999105930328369140625) * uData[6].y)) * uData[0].zw;
            highp vec2 _1289 = clamp(_1256 + _1287, vec2(0.0), vec2(1.0));
            highp vec2 _1291 = clamp(_1256 - _1287, vec2(0.0), vec2(1.0));
            highp vec4 _1295 = textureLod(uSampler, _1289, 0.0);
            highp float _1300 = _1260.w;
            highp float _1301 = (_1295.x / max(_1295.w, 9.9999997473787516355514526367188e-05)) * _1300;
            highp vec4 _1302 = _1260;
            _1302.x = _1301;
            highp vec4 _1306 = textureLod(uSampler, _1291, 0.0);
            highp float _1311 = (_1306.z / max(_1306.w, 9.9999997473787516355514526367188e-05)) * _1300;
            _1302.z = _1311;
            highp vec4 _1339;
            if (_1262)
            {
                highp vec4 _1321 = textureLod(uTex1, _1289, 0.0);
                highp vec4 _1328 = _1270;
                _1328.x = (_1321.x / max(_1321.w, 9.9999997473787516355514526367188e-05)) * _1270.w;
                highp vec4 _1332 = textureLod(uTex1, _1291, 0.0);
                _1328.z = (_1332.z / max(_1332.w, 9.9999997473787516355514526367188e-05)) * _1270.w;
                _1339 = _1328;
            }
            else
            {
                highp vec4 _1316 = _1270;
                _1316.x = _1301;
                _1316.z = _1311;
                _1339 = _1316;
            }
            _1340 = _1339;
            _1341 = _1302;
        }
        else
        {
            _1340 = _1270;
            _1341 = _1260;
        }
        bool _1343 = uData[4].x > 1.5;
        highp float _1357;
        if (_1343)
        {
            _1357 = uData[3].w;
        }
        else
        {
            highp float _1355;
            if ((uData[6].x - 2.0 * trunc(uData[6].x / 2.0)) > 0.5)
            {
                _1355 = 1.0;
            }
            else
            {
                _1355 = _1341.w;
            }
            _1357 = _1355;
        }
        highp vec4 _1366 = vec4(_1341.xyz / vec3(max(_1341.w, 9.9999997473787516355514526367188e-05)), 1.0);
        highp vec4 _1375 = vec4(_1340.xyz / vec3(max(_1340.w, 9.9999997473787516355514526367188e-05)), 1.0);
        highp float _1382;
        if (_1343)
        {
            _1382 = 1.0;
        }
        else
        {
            _1382 = (uData[4].z > 0.5) ? uData[4].x : 0.0;
        }
        bool _1386;
        if (_139)
        {
            _1386 = !_1343;
        }
        else
        {
            _1386 = false;
        }
        highp float _1395;
        if (_1386)
        {
            _1395 = _1382 * (1.0 - ((_1254 * _1254) * (1.0 - smoothstep(0.800000011920928955078125, 1.0, _1382))));
        }
        else
        {
            _1395 = _1382;
        }
        highp float _1398 = 1.0 - _1395;
        highp float _1406;
        if (_139)
        {
            _1406 = _1254;
        }
        else
        {
            _1406 = _1214 * _1214;
        }
        highp float _1409 = clamp(((uData[2].y * _1220) * _1406) * _1398, 0.0, 1.0);
        highp vec4 _1415 = ((_1375 * _1409) + ((mix(_1375, _1366, vec4(clamp(_1194.x, 0.0, 1.0))) * _1398) * (1.0 - _1409))) + (uData[3] * _1395);
        highp vec4 _1458;
        if (_1343)
        {
            _1458 = vec4(uData[3].xyz / vec3(max(uData[3].w, 9.9999997473787516355514526367188e-05)), 1.0);
        }
        else
        {
            highp vec4 _1422 = _1415 + (_1366 * (1.0 - _1415.w));
            highp vec4 _1448;
            if (uData[7].w < 1.0)
            {
                highp vec3 _1427 = _1422.xyz;
                highp float _1428 = dot(_1427, vec3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875));
                highp float _1429 = 0.60000002384185791015625 * uData[7].w;
                highp float _1431 = max(uData[7].w - _1429, 9.9999997473787516355514526367188e-05);
                highp float _1443;
                if (_1428 <= _1429)
                {
                    _1443 = _1428;
                }
                else
                {
                    _1443 = _1429 + (_1431 * (1.0 - exp((-(_1428 - _1429)) / _1431)));
                }
                highp vec3 _1446 = _1427 * (_1443 / max(_1428, 9.9999997473787516355514526367188e-05));
                _1448 = vec4(_1446.x, _1446.y, _1446.z, _1422.w);
            }
            else
            {
                _1448 = _1422;
            }
            _1458 = _1448;
        }
        highp float _1461 = dot(_1203, uData[9].xy);
        highp float _1462 = max(_1461, 0.0);
        highp float _1464 = max(-_1461, 0.0);
        highp float _1467 = abs(_1461);
        bool _1471;
        if (_139)
        {
            _1471 = uData[6].z > 0.0;
        }
        else
        {
            _1471 = false;
        }
        bool _1473 = uData[10].x > 0.0;
        highp float _1497;
        if (_1473)
        {
            _1497 = 0.0;
        }
        else
        {
            highp float _1496;
            if (_1471)
            {
                _1496 = (uData[6].z * (1.0 - smoothstep(0.20000000298023223876953125, 0.699999988079071044921875, _1467))) * exp((-max(0.0, -_1180)) / (uData[2].z * 2.5));
            }
            else
            {
                _1496 = uData[8].x * (1.0 - smoothstep(0.0, uData[2].z * 0.625, -_1180));
            }
            _1497 = _1496;
        }
        highp float _1507;
        if (_139)
        {
            _1507 = max((uData[5].w * _1254) * _1254, _1497) * min(_1220, 1.0);
        }
        else
        {
            _1507 = 0.0;
        }
        highp float _1510 = _1357 * (1.0 - _1507);
        highp vec4 _1516 = vec4(_1458.xyz * _1510, _1510 + _1507);
        highp float _1538;
        if (_139)
        {
            highp float _1537;
            if (_1471)
            {
                _1537 = uData[6].z * max(smoothstep(0.75, 1.0, _1467), max(_1208.x, _1208.y));
            }
            else
            {
                _1537 = 0.25;
            }
            _1538 = _1537;
        }
        else
        {
            _1538 = (0.449999988079071044921875 * ((_1462 * sqrt(_1462)) + ((0.75 * _1464) * sqrt(_1464)))) + 0.0599999986588954925537109375;
        }
        highp float _1565;
        if (_1471)
        {
            _1565 = exp((-max(0.0, -_1180)) / (uData[2].z * 1.25));
        }
        else
        {
            highp float _1559;
            if (_139)
            {
                highp float _1552 = -_1180;
                _1559 = smoothstep(uData[2].z * 0.3125, uData[2].z * 0.625, _1552) * (1.0 - smoothstep(uData[2].z * 1.5, uData[2].z * 2.0, _1552));
            }
            else
            {
                _1559 = exp((-max(0.0, -_1180)) / uData[2].z);
            }
            _1565 = _1559;
        }
        highp float _1577;
        if (_1473)
        {
            _1577 = 0.0;
        }
        else
        {
            highp float _1575;
            if (_139)
            {
                _1575 = 0.0;
            }
            else
            {
                _1575 = (0.039999999105930328369140625 * exp(_1211 / uData[1].w)) * _1462;
            }
            _1577 = (_1565 * _1538) + _1575;
        }
        highp vec2 _1578 = mix(_1131, _1130, _1204);
        highp float _1582 = _1578.y;
        highp float _1588 = clamp((vTextureCoord.y - (_1578.x - _1582)) / max(2.0 * _1582, 9.9999997473787516355514526367188e-05), 0.0, 1.0);
        highp float _1606;
        if (uData[4].z > 0.5)
        {
            _1606 = uData[4].y + ((uData[7].x + ((uData[7].y - uData[7].x) * _1588)) + (uData[7].z * (1.0 - smoothstep(0.0, 0.37999999523162841796875, _1588))));
        }
        else
        {
            _1606 = 0.0;
        }
        highp vec3 _1616 = _1516.xyz + vec3(clamp((_1606 + _1194.z) + ((_1220 * uData[2].w) * _1577), 0.0, 1.0));
        highp vec4 _1688;
        if (_1473)
        {
            highp vec2 _1626;
            if (dot(_1203, _1203) > 9.9999999392252902907785028219223e-09)
            {
                _1626 = normalize(_1203);
            }
            else
            {
                _1626 = vec2(0.0);
            }
            highp float _1627 = dot(_1626, uData[9].xy);
            highp float _1629 = mix(8.0, 1.0, uData[9].z);
            highp float _1637 = pow(max(_1627, 0.0), _1629) + (uData[9].w * pow(max(-_1627, 0.0), _1629));
            highp float _1638 = min(_1220, 1.0);
            highp float _1645 = -_1180;
            highp float _1647 = smoothstep(-0.5, 0.5, _1645);
            highp float _1649 = -max(0.0, _1645);
            highp vec3 _1686 = (_1616.xyz * (1.0 - (((uData[10].z * (1.0 - abs(_1627))) * (_1647 * exp(_1649 / max(uData[2].z * 2.5, 0.001000000047497451305389404296875)))) * _1638))) + vec3(_1638 * (((uData[10].x * max(_1637, max(_1208.x, uData[9].w * _1208.y))) * (_1647 * exp(_1649 / max(uData[8].y, 0.001000000047497451305389404296875)))) + ((uData[10].y * _1637) * (smoothstep(uData[8].y - 0.5, uData[8].y + 0.5, _1645) * exp((-max(0.0, _1645 - uData[8].y)) / max(uData[8].z, 0.001000000047497451305389404296875))))));
            _1688 = vec4(_1686.x, _1686.y, _1686.z, _1516.w);
        }
        else
        {
            _1688 = vec4(_1616.x, _1616.y, _1616.z, _1516.w);
        }
        highp vec4 _1689 = clamp(_1688, vec4(0.0), vec4(1.0));
        highp float _1696 = max(_1689.w, max(_1689.x, max(_1689.y, _1689.z)));
        highp vec4 _1697 = _1689;
        _1697.w = _1696;
        highp vec3 _1708 = _1697.xyz + vec3(((fract(52.98291778564453125 * fract(dot(vTextureCoord, vec2(0.067110560834407806396484375, 0.005837149918079376220703125)))) - 0.5) * uData[5].x) * _1696);
        _1712 = clamp(vec4(_1708.x, _1708.y, _1708.z, _1697.w), vec4(0.0), vec4(1.0)) * _1183;
        break;
    } while(false);
    out_var_SV_Target0 = _1712;
}

