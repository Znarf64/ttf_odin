package ttf_odin

import "base:intrinsics"
import "base:runtime"

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:slice/heap"
import "core:strings"
import "core:time"
import "core:math"
import la "core:math/linalg"
import "core:prof/spall"
import "core:os"

import stbi  "vendor:stb/image"
import stbtt "vendor:stb/truetype"

spall_ctx: spall.Context
@(thread_local)
spall_buffer: spall.Buffer

File_Header :: struct {
	sfntVesion:    u32be,
	numTables:     u16be,
	searchRange:   u16be,
	entrySelector: u16be,
	rangeShift:    u16be,
}

Font :: struct {
	data:          []byte,
	glyph_count:   int,
	units_per_em:  int,
	loca_offset:   int,
	glyf_offset:   int,
	hmtx_offset:   int,
	cmap_offset:   int,
	cmap_record:   ^Cmap_Encoding_Record,
	loca_32_bit:   bool,
	ascender:      int,
	descender:     int,
	cap_height:    int,
	hmetric_count: int,
}

Cmap_Platform_Id :: enum u16be {
	Unicode   = 0,
	Macintosh = 1,
	ISO       = 2,
	Windows   = 3,
	Custom    = 4,
}

Cmap_Encoding_Record :: struct {
	platformId: Cmap_Platform_Id,
	encodingId: u16be,
	offset:     u32be,
}

Cmap_Subtable_Format_12 :: struct {
	format:    u16be,
	_reserved: u16be,
	length:    u32be,
	language:  u32be,
	numGroups: u32be,
	groups:    [0]Sequential_Map_Group,
}

Sequential_Map_Group :: struct {
	startCharCode: u32be,
	endCharCode:   u32be,
	startGlyphId:  u32be,
}

Cmap_Subtable_Format_4 :: struct {
	format:         u16be,
	length:         u16be,
	language:       u16be,
	segCountX2:     u16be,
	_searchRange:   u16be,
	_entrySelector: u16be,
	_rangeShift:    u16be,
	data:           [0]byte,
}

Table_Record :: struct {
	tableTag: [4]u8 `fmt:"s"`,
	checksum: u32be `fmt:"#08x"`,
	offset:   u32be `fmt:"#08x"`,
	length:   u32be `fmt:"#08x"`,
}

@(require_results)
read_typed :: proc(bytes: []byte, $T: typeid, offset: int) -> (ret: T, ok: bool) {
	if len(bytes) < size_of(T) + offset {
		return
	}
	mem.copy(&ret, &bytes[offset], size_of(T))
	ok = true
	return
}

@(require_results)
load :: proc(data: []byte) -> (font: Font, ok: bool) {
	spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)

	font.data = data

	header := read_typed(data, File_Header, 0) or_return
	tables := ([^]Table_Record)(&data[size_of(header)])[:header.numTables]

	for &table in tables {
		name := strings.truncate_to_byte(string(table.tableTag[:]), 0)
		switch name {
		case "maxp":
			Maxp_Table :: struct {
				version:   [2]u16be,
				numGlyphs: u16be,
			}

			maxp_table      := (^Maxp_Table)(&data[table.offset])
			font.glyph_count = int(maxp_table.numGlyphs)
		case "head":
			Font_Header_Table :: struct #packed {
				majorVersion:       u16be,
				minorVersion:       u16be,
				fontRevision:       u32be,
				checksumAdjustment: u32be,
				magicNumber:        u32be,
				flags:              u16be,
				unitsPerEm:         u16be,
				created:            i64be,
				modified:           i64be,
				xMin:               i16be,
				yMin:               i16be,
				xMax:               i16be,
				yMax:               i16be,
				macStyle:           u16be,
				lowestRecPPEM:      u16be,
				fontDirectionHint:  i16be,
				indexToLocFormat:   i16be,
				glyphDataFormat:    i16be,
			}

			font_header_table := (^Font_Header_Table)(&data[table.offset])
			font.units_per_em  = int(font_header_table.unitsPerEm)
			font.loca_32_bit   = font_header_table.indexToLocFormat == 1
		case "hhea":
			Hhea_Table :: struct {
				majorVersion:        u16,
				minorVersion:        u16,
				ascender:            i16,
				descender:           i16,
				lineGap:             i16,
				advanceWidthMax:     u16,
				minLeftSideBearing:  i16,
				minRightSideBearing: i16,
				xMaxExtent:          i16,
				caretSlopeRise:      i16,
				caretSlopeRun:       i16,
				caretOffset:         i16,
				_reserved:           [4]i16,
				metricDataFormat:    i16,
				numberOfHMetrics:    u16,
			}

			hhea_table := (^Hhea_Table)(&data[table.offset])
			if font.ascender  == 0 do font.ascender  = int(hhea_table.ascender)
			if font.descender == 0 do font.descender = int(hhea_table.descender)
			font.hmetric_count = int(hhea_table.numberOfHMetrics)
		case "OS/2":
			OS2_Table :: struct #packed {
				version:                 u16be,
				xAvgCharWidth:           i16be,
				usWeightClass:           u16be,
				usWidthClass:            u16be,
				fsType:                  u16be,
				ySubscriptXSize:         i16be,
				ySubscriptYSize:         i16be,
				ySubscriptXOffset:       i16be,
				ySubscriptYOffset:       i16be,
				ySuperscriptXSize:       i16be,
				ySuperscriptYSize:       i16be,
				ySuperscriptXOffset:     i16be,
				ySuperscriptYOffset:     i16be,
				yStrikeoutSize:          i16be,
				yStrikeoutPosition:      i16be,
				sFamilyClass:            i16be,
				panose:                  [10]u8,
				ulUnicodeRange1:         u32be,
				ulUnicodeRange2:         u32be,
				ulUnicodeRange3:         u32be,
				ulUnicodeRange4:         u32be,
				achVendID:               [4]u8,
				fsSelection:             u16be,
				usFirstCharIndex:        u16be,
				usLastCharIndex:         u16be,
				sTypoAscender:           i16be,
				sTypoDescender:          i16be,
				sTypoLineGap:            i16be,
				usWinAscent:             u16be,
				usWinDescent:            u16be,
				ulCodePageRange1:        u32be,
				ulCodePageRange2:        u32be,
				sxHeight:                i16be,
				sCapHeight:              i16be,
				usDefaultChar:           u16be,
				usBreakChar:             u16be,
				usMaxContext:            u16be,
				usLowerOpticalPointSize: u16be,
				usUpperOpticalPointSize: u16be,
			}

			os2_table: OS2_Table
			mem.copy(&os2_table, &data[table.offset], size_of(os2_table))
			font.ascender   = int(os2_table.sTypoAscender)
			font.descender  = int(os2_table.sTypoDescender)
			font.cap_height = int(os2_table.sCapHeight)
		case "loca":
			font.loca_offset = int(table.offset)
		case "glyf":
			font.glyf_offset = int(table.offset)
		case "cmap":
			font.cmap_offset = int(table.offset)

			Cmap_Header :: struct {
				version, numTables: u16be,
			}

			cmap_header      := (^Cmap_Header)(&data[table.offset])
			encoding_records := ([^]Cmap_Encoding_Record)(&data[table.offset + size_of(Cmap_Header)])[:cmap_header.numTables]

			record: ^Cmap_Encoding_Record
			for &r in encoding_records {
				if r.platformId != .Unicode {
					continue
				}
				if r.encodingId == 3 && record == nil {
					record = &r
				}
				if r.encodingId == 4 {
					record = &r
				}
			}

			assert(record != nil)
			font.cmap_record = record
		case "hmtx":
			font.hmtx_offset = int(table.offset)
		}
	}
	
	ok = true
	return
}

Shape :: struct {
	linears:  []Segment_Linear,
	beziers:  []Segment_Bezier,
	min, max: [2]f32,
}

Glyph :: distinct int

Glyph_Header :: struct {
	numberOfContours: i16be,
	xMin:             i16be,
	yMin:             i16be,
	xMax:             i16be,
	yMax:             i16be,
}

@(require_results)
get_glyph_header :: proc(font: Font, glyph: Glyph) -> ^Glyph_Header {
	offset, next: int
	if font.loca_32_bit {
		offset = int(([^]u32be)(&font.data[font.loca_offset])[glyph + 0])
		next   = int(([^]u32be)(&font.data[font.loca_offset])[glyph + 1])
	} else {
		offset = int(([^]u16be)(&font.data[font.loca_offset])[glyph + 0]) * 2
		next   = int(([^]u16be)(&font.data[font.loca_offset])[glyph + 1]) * 2
	}
	if offset == next {
		return nil
	}
	assert(next - offset >= size_of(Glyph_Header))
	return (^Glyph_Header)(&font.data[font.glyf_offset + int(offset)])
}

Segment_Linear :: struct { a, b:       [2]f32, }
Segment_Bezier :: struct { p0, p1, p2: [2]f32, }

@(require_results)
get_glyph_shape :: proc(font: Font, glyph: Glyph, allocator := context.allocator) -> (shape: Shape) {
	spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)

	glyph_header := get_glyph_header(font, glyph)
	if glyph_header == nil {
		return
	}

	shape.min.x = f32(glyph_header.xMin)
	shape.max.x = f32(glyph_header.xMax)
	shape.min.y = f32(glyph_header.yMin)
	shape.max.y = f32(glyph_header.yMax)

	linears := make([dynamic]Segment_Linear, allocator)
	beziers := make([dynamic]Segment_Bezier, allocator)

	bezier_less :: proc(a, b: Segment_Bezier) -> bool {
		return a.p0.y < b.p0.y
	}

	linear_less :: proc(a, b: Segment_Linear) -> bool {
		return a.a.y < b.a.y
	}

	if glyph_header.numberOfContours >= 0 {
		spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "get_glyph_shape::collect_points")

		description        := ([^]byte)(glyph_header)[size_of(glyph_header^):]
		end_points         := ([^]u16be)(description)[:glyph_header.numberOfContours]
		instruction_length := ([^]u16be)(description)[glyph_header.numberOfContours]
		n_points           := int(end_points[glyph_header.numberOfContours - 1] + 1)
		points             := description[int(glyph_header.numberOfContours) * size_of(u16be) + size_of(u16be) + int(instruction_length):]

		reserve(&linears, n_points + 1)
		reserve(&beziers, n_points + 1)

		linears.allocator = mem.panic_allocator()
		beziers.allocator = mem.panic_allocator()

		flags  := make([]Simple_Glyph_Flags, n_points, context.temp_allocator)
		coords := make([][2]f32,             n_points, context.temp_allocator)

		Simple_Glyph_Flag :: enum {
			ON_CURVE_POINT                       = intrinsics.constant_log2(0x01),
			X_SHORT_VECTOR                       = intrinsics.constant_log2(0x02),
			Y_SHORT_VECTOR                       = intrinsics.constant_log2(0x04),
			REPEAT_FLAG                          = intrinsics.constant_log2(0x08),
			X_IS_SAME_OR_POSITIVE_X_SHORT_VECTOR = intrinsics.constant_log2(0x10),
			Y_IS_SAME_OR_POSITIVE_Y_SHORT_VECTOR = intrinsics.constant_log2(0x20),
			OVERLAP_SIMPLE                       = intrinsics.constant_log2(0x40),
		}
		Simple_Glyph_Flags :: bit_set[Simple_Glyph_Flag; u8]

		{
			spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "get_glyph_shape::flag")
			flag: Simple_Glyph_Flags
			for i := 0; i < n_points; i += 1 {
				flag   = transmute(Simple_Glyph_Flags)points[0]
				points = points[1:]
				if .REPEAT_FLAG in flag {
					repeat_count := int(points[0])
					points        = points[1:]
					for j in 0 ..< repeat_count + 1 {
						flags[i + j] = flag
					}
					i += repeat_count
				} else {
					flags[i] = flag
				}
			}
		}

		{
			spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "get_glyph_shape::x")
			x: int
			for i in 0 ..< n_points {
				flag := flags[i]
				if .X_SHORT_VECTOR in flag {
					dx    := int(points[0])
					points = points[1:]
					x     += (.X_IS_SAME_OR_POSITIVE_X_SHORT_VECTOR in flag) ? dx : -dx
				} else {
					if .X_IS_SAME_OR_POSITIVE_X_SHORT_VECTOR not_in flag {
						x     += int((^i16be)(points)^)
						points = points[2:]
					}
				}
				coords[i].x = f32(x)
			}
		}

		{
			spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "get_glyph_shape::y")
			y: int
			for i in 0 ..< n_points {
				flag := flags[i]
				if .Y_SHORT_VECTOR in flag {
					dy    := int(points[0])
					points = points[1:]
					y     += (.Y_IS_SAME_OR_POSITIVE_Y_SHORT_VECTOR in flag) ? dy : -dy
				} else {
					if .Y_IS_SAME_OR_POSITIVE_Y_SHORT_VECTOR not_in flag {
						y     += int((^i16be)(points)^)
						points = points[2:]
					}
				}
				coords[i].y = f32(y)
			}
		}

		spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "get_glyph_shape::collect_contours")

		current: int
		for c in 0 ..< glyph_header.numberOfContours {
			end := int(end_points[c])

			prev:    [2]f32
			prev_on: bool

			if .ON_CURVE_POINT in flags[end] {
				prev    = coords[end]
				prev_on = true
			} else {
				prev    = (coords[current] + coords[end]) / 2
				prev_on = false
			}

			start := current
			for current <= end {
				if .ON_CURVE_POINT in flags[current] {
					if prev_on {
						if prev.y < coords[current].y {
							append(&linears, Segment_Linear { a = prev, b = coords[current], })
						} else {
							append(&linears, Segment_Linear { a = coords[current], b = prev, })
						}
					} else {
						prev_on = true
					}
					prev = coords[current]
				} else {
					insert_bezier :: proc(beziers: ^[dynamic]Segment_Bezier, bezier: Segment_Bezier) {
						push :: proc(beziers: ^[dynamic]Segment_Bezier, bezier: Segment_Bezier) {
							// assert(bezier.p0.y <= bezier.p1.y)
							// assert(bezier.p1.y <= bezier.p2.y)
							append(beziers, bezier)
						}

						bezier := bezier

						if bezier.p0.y > bezier.p2.y {
							bezier.p0, bezier.p2 = bezier.p2, bezier.p0
						}
						denom := bezier.p0.y - 2 * bezier.p1.y + bezier.p2.y
						if abs(denom) < 0.0001 {
							bezier.p1.y = clamp(bezier.p1.y, bezier.p0.y, bezier.p2.y)
							push(beziers, bezier)
						} else {
							t_split := (bezier.p0.y - bezier.p1.y) / denom
							if 0 < t_split && t_split < 1 {
								assert((bezier.p1.y > bezier.p2.y) != (bezier.p1.y < bezier.p0.y))

								q0 := math.lerp(bezier.p0, bezier.p1, t_split)
								q1 := math.lerp(bezier.p1, bezier.p2, t_split)
								s  := math.lerp(q0,        q1,        t_split)

								if bezier.p1.y > bezier.p2.y {
									push(beziers, Segment_Bezier { bezier.p0, q0, s, })
									push(beziers, Segment_Bezier { bezier.p2, q1, s, })
								} else {
									push(beziers, Segment_Bezier { s, q0, bezier.p0, })
									push(beziers, Segment_Bezier { s, q1, bezier.p2, })
								}
							} else {
								push(beziers, bezier)
							}
						}
					}

					next := current + 1
					if next > end {
						next = start
					}

					if .ON_CURVE_POINT in flags[next] {
						insert_bezier(&beziers, { p0 = prev, p1 = coords[current], p2 = coords[next], })
						prev     = coords[next]
						current += 1
					} else {
						mid := (coords[current] + coords[next]) / 2
						insert_bezier(&beziers, { p0 = prev, p1 = coords[current], p2 = mid, })
						prev = mid
					}
				}
				current += 1
			}

			current = end + 1
		}
	} else {
		Component_Glyph_Flag :: enum {
			ARG_1_AND_2_ARE_WORDS     = intrinsics.constant_log2(0x0001),
			ARGS_ARE_XY_VALUES        = intrinsics.constant_log2(0x0002),
			ROUND_XY_TO_GRID          = intrinsics.constant_log2(0x0004),
			WE_HAVE_A_SCALE           = intrinsics.constant_log2(0x0008),
			MORE_COMPONENTS           = intrinsics.constant_log2(0x0020),
			WE_HAVE_AN_X_AND_Y_SCALE  = intrinsics.constant_log2(0x0040),
			WE_HAVE_A_TWO_BY_TWO      = intrinsics.constant_log2(0x0080),
			WE_HAVE_INSTRUCTIONS      = intrinsics.constant_log2(0x0100),
			USE_MY_METRICS            = intrinsics.constant_log2(0x0200),
			OVERLAP_COMPOUND          = intrinsics.constant_log2(0x0400),
			SCALED_COMPONENT_OFFSET   = intrinsics.constant_log2(0x0800),
			UNSCALED_COMPONENT_OFFSET = intrinsics.constant_log2(0x1000),
	    }
		Component_Glyph_Flags :: bit_set[Component_Glyph_Flag; u16be]

		flags := Component_Glyph_Flags { .MORE_COMPONENTS, }
		data  := ([^]u16be)(([^]byte)(glyph_header)[size_of(glyph_header^):])

		for (.MORE_COMPONENTS in flags) {
			flags        = transmute(Component_Glyph_Flags)data[0]
			glyph_index := Glyph(data[1])
			data         = data[2:]

			subshape := get_glyph_shape(font, glyph_index, context.temp_allocator)

			if .ARGS_ARE_XY_VALUES in flags {
				args: [2]f32
				if .ARG_1_AND_2_ARE_WORDS in flags {
					args[0] = f32(i16be(data[0]))
					args[1] = f32(i16be(data[1]))
					data    = data[2:]
				} else {
					args8  := transmute([2]i8)data[0]
					data    = data[1:]
					args[0] = f32(args8[0])
					args[1] = f32(args8[1])
				}

				for &bezier in subshape.beziers {
					bezier.p0[0] += f32(args[0])
					bezier.p0[1] += f32(args[1])

					bezier.p1[0] += f32(args[0])
					bezier.p1[1] += f32(args[1])

					bezier.p2[0] += f32(args[0])
					bezier.p2[1] += f32(args[1])
				}

				for &linear in subshape.linears {
					linear.a[0] += f32(args[0])
					linear.a[1] += f32(args[1])

					linear.b[0] += f32(args[0])
					linear.b[1] += f32(args[1])
				}
			}

			if .WE_HAVE_A_SCALE in flags {
				scale := f32(i16be(data[0])) / (1 << 14)
				data   = data[1:]

				for &bezier in subshape.beziers {
					bezier.p0 *= scale
					bezier.p1 *= scale
					bezier.p2 *= scale
				}
				for &linear in subshape.linears {
					linear.a *= scale
					linear.b *= scale
				}
			}
			if .WE_HAVE_AN_X_AND_Y_SCALE in flags {
				scale_x := i16be(data[0])
				scale_y := i16be(data[1])
				data     = data[2:]

				scale := [2]f32 {
					f32(scale_x),
					f32(scale_y),
				} / (1 << 14)

				for &bezier in subshape.beziers {
					bezier.p0 *= scale
					bezier.p1 *= scale
					bezier.p2 *= scale
				}
				for &linear in subshape.linears {
					linear.a *= scale
					linear.b *= scale
				}
			}
			if .WE_HAVE_A_TWO_BY_TWO in flags {
				values: [4]u16be
				mem.copy(&values, data, size_of(values))
				data = data[4:]

				mat: matrix[2, 2]f32
				for i in 0 ..< 4 {
					mat[i / 2, i % 2] = f32(values[i]) / (1 << 14)
				}

				for &bezier in subshape.beziers {
					bezier.p0 *= mat
					bezier.p1 *= mat
					bezier.p2 *= mat
				}
				for &linear in subshape.linears {
					linear.a *= mat
					linear.b *= mat
				}
			}
			if .WE_HAVE_INSTRUCTIONS in flags {
				n_instructions := u16be(data[0])
				data            = data[1 + n_instructions:]
			}

			append(&beziers, ..subshape.beziers[:])
			append(&linears, ..subshape.linears[:])
		}
	}

	{
		spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, "get_glyph_shape::sort_curves")

		radix_sort_by :: proc(data: $S/[]$E, f: proc(e: E) -> $T) where intrinsics.type_is_integer(T) {
			Bucket :: [dynamic]E

			BUCKETS_LOG2 :: 8
			BUCKETS      :: 1 << BUCKETS_LOG2
			RADIX_MASK   :: BUCKETS - 1

			when !intrinsics.type_is_unsigned(T) {
				_sign_bit_mask := u128(1 << (size_of(T) * 8 - 1))
				sign_bit_mask  := T(_sign_bit_mask)
			}

			buckets: [BUCKETS]Bucket
			defer for b in buckets {
				delete(b)
			}

			shift: uint
			for shift < size_of(T) * 8 {
				for elem in data {
					key := f(elem)
					when intrinsics.type_is_unsigned(T) {
						append(&buckets[int(key >> shift) & RADIX_MASK], elem)
					} else {
						append(&buckets[int((key ~ sign_bit_mask) >> shift) & RADIX_MASK], elem)
					}
				}

				i := 0
				for &bucket in buckets {
					for e in bucket {
						data[i] = e
						i      += 1
					}
					clear(&bucket)
				}

				shift += BUCKETS_LOG2
			}
		}

		// radix_sort_by(beziers[:], proc(bezier: Segment_Bezier) -> u32 {
		// 	f := bezier.p0.y
		// 	if f < 0 {
		// 		return 0x7FFF_FFFF - transmute(u32)f & 0x7FFF_FFFF
		// 	} else {
		// 		return transmute(u32)f + 0x7FFF_FFFF
		// 	}
		// })

		// radix_sort_by(linears[:], proc(linear: Segment_Linear) -> u32 {
		// 	f := linear.a.y
		// 	if f < 0 {
		// 		return 0x7FFF_FFFF - transmute(u32)f & 0x7FFF_FFFF
		// 	} else {
		// 		return transmute(u32)f + 0x7FFF_FFFF
		// 	}
		// })

		heap.make(linears[:], linear_less)
		heap.sort(linears[:], linear_less)

		heap.make(beziers[:], bezier_less)
		heap.sort(beziers[:], bezier_less)

		// slice.sort_by(linears[:], linear_less)
		// slice.sort_by(beziers[:], bezier_less)
	}

	shape.beziers = beziers[:]
	shape.linears = linears[:]
	return
}

get_intersections :: proc(
	beziers:       []Segment_Bezier,
	linears:       []Segment_Linear,
	y:             f32,
	intersections: []f32,
) -> (n_intersections: int) {
	for linear in linears {
		if !(linear.a.y <= y && y < linear.b.y) {
			continue
		}

		t  := (y - linear.a.y) / (linear.b.y - linear.a.y)
		vx := (1 - t) * linear.a.x + t * linear.b.x

		intersections[n_intersections] = vx
		n_intersections               += 1

		heap.push(intersections[:n_intersections], proc(a, b: f32) -> bool {
			return a < b
		})
	}

	for bezier in beziers {
		if !(bezier.p0.y <= y && y < bezier.p2.y) {
			continue
		}

		a := bezier.p0.y - 2 * bezier.p1.y + bezier.p2.y
		b := -2 * bezier.p0.y + 2 * bezier.p1.y
		c := bezier.p0.y - y

		t: f32
		if abs(a) < 0.0001 {
			t = (y - bezier.p0.y) / (bezier.p2.y - bezier.p0.y)
	    } else {
			t = (-b + math.sqrt(b * b - 4 * a * c)) / (2 * a)
	    }

		vx                            := math.lerp(math.lerp(bezier.p0.x, bezier.p1.x, t), math.lerp(bezier.p1.x, bezier.p2.x, t), t)
		intersections[n_intersections] = vx
		n_intersections               += 1

		heap.push(intersections[:n_intersections], proc(a, b: f32) -> bool {
			return a < b
		})
	}

	heap.sort(intersections[:n_intersections], proc(a, b: f32) -> bool {
		return a < b
	})

	return
}

@(require_results)
get_codepoint_glyph :: proc(font: Font, codepoint: rune) -> Glyph {
	spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)

	codepoint := u32(codepoint)

	if font.cmap_record.platformId != .Unicode {
		return 0
	}

	switch font.cmap_record.encodingId {
	case 3:
		subtable := (^Cmap_Subtable_Format_4)(&font.data[font.cmap_offset + int(font.cmap_record.offset)])
		assert(subtable.format == 4)

		seg_count := u32(subtable.segCountX2 / 2)

		data           := ([^]u16be)(raw_data(&subtable.data))
		endCodes       :=                   data[:seg_count]; data = data[seg_count:]
		data            =                   data[1:]
		startCodes     :=                   data[:seg_count]; data = data[seg_count:]
		idDeltas       := transmute([]i16be)data[:seg_count]; data = data[seg_count:]
		idRangeOffsets :=                   data[:seg_count]; data = data[seg_count:]
		glyphIdArray   :=                   data

		// TODO: do binary search
		for i in 0 ..< seg_count {
			start := u32(startCodes[i])
			end   := u32(endCodes[i])

			if !(start <= codepoint && codepoint <= end) {
				continue
			}

			delta := u32(idDeltas[i])

			if idRangeOffsets[i] == 0 {
				return Glyph((codepoint + delta) & 0xFFFF)
			}

			range_offset := u32(idRangeOffsets[i]) / 2
			glyph_index  := range_offset + (codepoint - start) - (seg_count - i)

			glyph := u32(glyphIdArray[glyph_index])
			if glyph == 0 {
				return 0
			}

			return Glyph((glyph + delta) & 0xFFFF)
		}
	case 4:
		subtable := (^Cmap_Subtable_Format_12)(&font.data[font.cmap_offset + int(font.cmap_record.offset)])
		assert(subtable.format == 12)
		#no_bounds_check groups := subtable.groups[:subtable.numGroups]
		group_index, found      := slice.binary_search_by(groups, codepoint, proc(group: Sequential_Map_Group, codepoint: u32) -> slice.Ordering {
			switch {
			case u32(group.startCharCode) > codepoint:
				return .Greater
			case u32(group.endCharCode) < codepoint:
				return .Less
			case:
				return .Equal
			}
		})
		if !found {
			return 0
		}
		return Glyph(u32(groups[group_index].startGlyphId) + codepoint - u32(groups[group_index].startCharCode))
	case:
		return 0
	}
	return 0
}

@(require_results)
font_height_to_scale :: proc(font: Font, font_height: f32) -> f32 {
	return font_height / f32(font.cap_height)
}

@(require_results)
get_bitmap_size :: proc(font: Font, shape: Shape, scale: [2]f32) -> (w: int, h: int) {
	min   := shape.min * scale
	max   := shape.max * scale
	w      = int(math.ceil(max.x) - math.floor(min.x))
	h      = int(math.ceil(max.y) - math.floor(min.y))
	return
}

render_shape_bitmap :: proc(
	font:     Font,
	shape:    Shape,
	scale:    [2]f32,
	pixels:   []u8,
	subpixel: bool = false,
	stride:   int  = -1,
) {
	spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)

	scale := scale
	w, h := get_bitmap_size(font, shape, scale)
	if subpixel {
		scale.x *= 3
		w       *= 3
	}

	stride := stride
	if stride <= 0 {
		stride = w
	}

	assert(len(pixels) >= stride * h)

	y_samples    := h < 10 ? 15 : 5
	max_coverage := f32(255 / y_samples)
	assert(255 % y_samples == 0)

	RANGE :: true

	when RANGE {
		beziers_start, beziers_end: int
		linears_start, linears_end: int
	} else {
		active_beziers := make([dynamic]Segment_Bezier, 0, len(shape.beziers), context.temp_allocator)
		active_linears := make([dynamic]Segment_Linear, 0, len(shape.linears), context.temp_allocator)
		beziers        := shape.beziers
		linears        := shape.linears
	}

	intersections := make([]f32, len(shape.linears) + len(shape.beziers), context.temp_allocator)
	scanline      := make([]u8, w, context.temp_allocator)
	for y in 0 ..< h {
		for y_sample in 0 ..< y_samples {
			render_y := (f32(y) + f32(y_sample) / f32(y_samples)) / scale.y + shape.min.y

			when RANGE {
				for beziers_start < len(shape.beziers) && shape.beziers[beziers_start].p2.y <= render_y {
					beziers_start += 1
				}
				for beziers_end < len(shape.beziers) && shape.beziers[beziers_end].p0.y <= render_y {
					beziers_end += 1
				}

				for linears_start < len(shape.linears) && shape.linears[linears_start].b.y <= render_y {
					linears_start += 1
				}
				for linears_end < len(shape.linears) && shape.linears[linears_end].a.y <= render_y {
					linears_end += 1
				}
			} else {
				for i := 0; i < len(active_beziers); {
					bezier := active_beziers[i]
					if bezier.p2.y <= render_y {
						unordered_remove(&active_beziers, i)
					} else {
						assert(bezier.p0.y <= render_y && render_y < bezier.p2.y)
						i += 1
					}
				}

				for len(beziers) != 0 && beziers[0].p0.y <= render_y {
					if render_y < beziers[0].p2.y {
						assert(beziers[0].p0.y <= render_y && render_y < beziers[0].p2.y)
						append(&active_beziers, beziers[0])
					}
					beziers = beziers[1:]
				}

				for i := 0; i < len(active_linears); {
					linear := active_linears[i]
					if linear.b.y <= render_y {
						unordered_remove(&active_linears, i)
					} else {
						assert(linear.a.y <= render_y && render_y < linear.b.y)
						i += 1
					}
				}

				for len(linears) != 0 && linears[0].a.y <= render_y {
					if render_y < linears[0].b.y {
						assert(linears[0].a.y <= render_y && render_y < linears[0].b.y)
						append(&active_linears, linears[0])
					}
					linears = linears[1:]
				}
			}

			when RANGE {
				n := get_intersections(
					shape.beziers[beziers_start:beziers_end],
					shape.linears[linears_start:linears_end],
					render_y,
					intersections,
				)
			} else {
				n := get_intersections(active_beziers[:], active_linears[:], render_y, intersections)
			}

			current_intersection: int
			for current_intersection < n - 1 {
				start := (intersections[current_intersection + 0] - shape.min.x) * scale.x + 0.5
				end   := (intersections[current_intersection + 1] - shape.min.x) * scale.x + 0.5

				if int(start) == int(end) {
					scanline[int(start)] += u8((end - start) * max_coverage)
				} else {
					if int(start) > 0 {
						scanline[int(start)] += u8((1 - start + f32(int(start))) * max_coverage)
					}
					for x in max(int(start), 0) + 1 ..< min(int(end), w) {
						scanline[x] += 255 / u8(y_samples)
					}
					if int(end) < w {
						scanline[int(end)] += u8((end - f32(int(end))) * max_coverage)
					}
				}

				current_intersection += 2
			}
		}

		if subpixel {
			for x in 0 ..< w {
				acc: f32
				acc += 1 * f32(scanline[clamp(x - 2, 0, w - 1)]) / 9
				acc += 2 * f32(scanline[clamp(x - 1, 0, w - 1)]) / 9
				acc += 3 * f32(scanline[clamp(x + 0, 0, w - 1)]) / 9
				acc += 2 * f32(scanline[clamp(x + 1, 0, w - 1)]) / 9
				acc += 1 * f32(scanline[clamp(x + 2, 0, w - 1)]) / 9
				pixels[(h - y - 1) * stride + x] = u8(acc)
			}
		} else {
			mem.copy(&pixels[(h - y - 1) * stride], raw_data(scanline), w)
		}
		slice.zero(scanline)
	}
}

// Randomly generated N-Rooks pattern with relatively good sample distribution and few bad alignments with angled lines
SAMPLING_PATTERN_16_DEFAULT :: [16]int {
	 0 = 13,
	 1 =  1,
	 2 =  9,
	 3 =  5,
	 4 = 14,
	 5 =  2,
	 6 = 11,
	 7 =  7,
	 8 =  0,
	 9 =  4,
	10 = 12,
	11 =  8,
	12 = 15,
	13 =  3,
	14 = 10,
	15 =  6,
}

SAMPLING_PATTERN_16_RGSS :: [16]int {
	 0 = 3,
	 1 = 7,
	 2 = 11,
	 3 = 15,

	 4 = 2,
	 5 = 6,
	 6 = 10,
	 7 = 14,

	 8 = 1,
	 9 = 5,
	10 = 9,
	11 = 13,

	12 = 0,
	13 = 4,
	14 = 8,
	15 = 12,
}

SAMPLING_PATTERN_8_DEFAULT :: [8]int {
	 0 = 4,
	 1 = 1,
	 2 = 6,
	 3 = 3,
	 4 = 0,
	 5 = 5,
	 6 = 2,
	 7 = 7,
}

sampling_mask_table_generate :: proc "contextless" (pattern: [$N]int) -> (table: [N]bit_set[0 ..< len(pattern)]) {
	transposed: [N]int
	for p, i in pattern {
		transposed[p] = i
	}
	mask: type_of(table[0])
	for p, i in transposed {
		mask         |= { p, }
		table[15 - i] = mask
	}
	return
}

coverage_mask_vertical :: proc(y: int, $Bits: int) -> bit_set[0 ..< Bits] {
	U :: intrinsics.type_bit_set_underlying_type(bit_set[0 ..< Bits])
	return transmute(bit_set[0 ..< 16])U((1 << uint(15 - y)) - 1)
}

render_shape_coverage_mask :: proc(
	font:             Font,
	shape:            Shape,
	scale:            [2]f32,
	sampling_pattern: [$N]int,
	pixels:           []bit_set[0 ..< len(sampling_pattern)],
	stride := -1,
) {
	spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)

	P :: type_of(pixels[0])

	intersections := make([]f32, len(shape.linears) + len(shape.beziers), context.temp_allocator)
	w, h          := get_bitmap_size(font, shape, scale)
	stride        := stride
	if stride <= 0 {
		stride = w
	}

	assert(len(pixels) >= stride * h)

	beziers_start, beziers_end: int
	linears_start, linears_end: int

	scanline := make([]P, w, context.temp_allocator)
	for y in 0 ..< h {
		for y_sample in 0 ..< N {
			render_y := (f32(y) + f32(y_sample) / N) / scale.y + shape.min.y

			for beziers_start < len(shape.beziers) && shape.beziers[beziers_start].p2.y <= render_y {
				beziers_start += 1
			}
			for beziers_end < len(shape.beziers) && shape.beziers[beziers_end].p0.y <= render_y {
				beziers_end += 1
			}

			for linears_start < len(shape.linears) && shape.linears[linears_start].b.y <= render_y {
				linears_start += 1
			}
			for linears_end < len(shape.linears) && shape.linears[linears_end].a.y <= render_y {
				linears_end += 1
			}

			n := get_intersections(
				shape.beziers[beziers_start:beziers_end],
				shape.linears[linears_start:linears_end],
				render_y,
				intersections,
			)

			current_intersection: int
			for current_intersection < n - 1 {
				x_off := sampling_pattern[N - 1 - y_sample]
				start := ((intersections[current_intersection + 0] - shape.min.x) * scale.x + 0.5) * N - f32(x_off)
				end   := ((intersections[current_intersection + 1] - shape.min.x) * scale.x - 0.5) * N - f32(x_off)

				x_start := int(math.round(start / N))
				x_end   := int(math.round(end   / N))

				for x in max(x_start, 0) ..= min(x_end, w - 1) {
					scanline[x] |= { N - 1 - y_sample, }
				}

				current_intersection += 2
			}
		}

		copy(pixels[(h - y - 1) * stride:], scanline)
		slice.zero(scanline)
	}
}

@(require_results)
get_glyph_horizontal_metrics :: proc(font: Font, glyph: Glyph) -> (x_advance, left_bearing: int) {
	Record :: struct {
		advanceWidth: u16be,
		lsb:          i16be,
	}
	records := ([^]Record)(&font.data[font.hmtx_offset])
	lsbs    := ([^]i16be )(records[font.hmetric_count:])

	if int(glyph) < font.hmetric_count {
		record := records[glyph]
		return int(record.advanceWidth), int(record.lsb)
	} else {
		return int(records[font.hmetric_count - 1].advanceWidth), int(lsbs[int(glyph) - font.hmetric_count])
	}
}

main :: proc() {
	spall_ctx = spall.context_create("trace_test.spall")
	defer spall.context_destroy(&spall_ctx)

	buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
	defer delete(buffer_backing)

	spall_buffer = spall.buffer_create(buffer_backing)
	defer spall.buffer_destroy(&spall_ctx, &spall_buffer)

	FONT_SIZE :: 100
	FONT_PATH :: "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf"
	// FONT_PATH :: "/usr/share/fonts/inter/InterVariable.ttf"
	// FONT_PATH :: "/usr/share/fonts/TTF/Inconsolata-Regular.ttf"
	font_data := os.read_entire_file(FONT_PATH, context.temp_allocator) or_else panic("Failed to read font data")

	// CODEPOINT :: ''
	CODEPOINT :: ''
	// CODEPOINT :: 'A'
	// CODEPOINT :: 'T'

	font      := load(font_data) or_else panic("Failed to load font")

	start     := time.now()

	glyph     := get_codepoint_glyph(font, CODEPOINT)
	scale     := ([2]f32)(font_height_to_scale(font, FONT_SIZE))
	shape     := get_glyph_shape(font, glyph)
	w, h      := get_bitmap_size(font, shape, scale)
	pixels    := make([]u8, w * h)

	{
		N :: 1

		for _ in 0 ..< N {
			glyph := get_codepoint_glyph(font, CODEPOINT)
			shape := get_glyph_shape(font, glyph)
			render_shape_bitmap(font, shape, scale, pixels)
		}

		fmt.println("time:", time.since(start) / N)
		stbi.write_png("out.png", i32(w), i32(h), 1, raw_data(pixels), 0)

		pixels = make([]u8, w * h * 3)
		render_shape_bitmap(font, shape, scale, pixels, subpixel = true)
		stbi.write_png("sub.png", i32(w), i32(h), 3, raw_data(pixels), 0)

		for &p in slice.reinterpret([][3]u8, pixels) {
			end   := [3]f32{ .878, .42,  .455, }
			start := [3]f32{ .898, .753, .478, }

			v := la.array_cast(p, f32) / 255
			v  = la.lerp(start, end, v)
			p  = la.array_cast(v * 255.999, u8)
		}
		stbi.write_png("col.png", i32(w), i32(h), 3, raw_data(pixels), 0)
	}

	SAMPLING_PATTERN :: SAMPLING_PATTERN_16_DEFAULT
	N                :: len(SAMPLING_PATTERN)
	P                :: bit_set[0 ..< N]

	mask_table       := sampling_mask_table_generate(SAMPLING_PATTERN)
	coverage         := make([]P,  (w + 1) * (h + 1))
	pixels            = make([]u8, (w * N) * (h * N))
	render_shape_coverage_mask(font, shape, scale, SAMPLING_PATTERN, coverage, w + 1)

	for x_shift in 0 ..< N {
		for y in 0 ..< h * N {
			for x in 0 ..< w * N {
				pixels[x + y * w * N] = (x / N + y / N) % 2 == 0 ? 64 : 32
			}
		}

		for y in 0 ..< h {
			for x in 0 ..< w {
				c := coverage[x + y * (w + 1)]
				for px, py in SAMPLING_PATTERN {
					pixels[int(px) + x * N + (py + y * N) * w * N] = 255 if py in c else 0
				}
			}
		}
		stbi.write_png("cov.png", i32(w * N), i32(h * N), 1, raw_data(pixels), 0)

		slice.zero(pixels)
		for y in 0 ..< h {
			for x in 0 ..< w {
				tl    := coverage[(x + 0) + (y + 0) * (w + 1)]
				tr    := coverage[(x + 1) + (y + 0) * (w + 1)]
				bl    := coverage[(x + 0) + (y + 1) * (w + 1)]
				br    := coverage[(x + 1) + (y + 1) * (w + 1)]
				xmask := mask_table[x_shift]
				ymask := transmute(P)(intrinsics.type_bit_set_underlying_type(P)((1 << uint(0)) - 1))

				result := (
					tl & ~xmask & ~ymask |
					tr &  xmask & ~ymask |
					bl & ~xmask &  ymask |
					br &  xmask &  ymask
				)

				coverage         := f32(card(result)) / N
				pixels[x + y * w] = u8(255.999 * coverage)
			}
		}

		stbi.write_png(fmt.ctprintf("cov_%c.png", rune(x_shift + 'a')), i32(w), i32(h), 1, raw_data(pixels), 0)
	}

	{
		fontinfo: stbtt.fontinfo
		stbtt.InitFont(&fontinfo, raw_data(font_data), 0)

		start_time := time.now()
		pixels     := make([^]u8, w * h)
		for _ in 0 ..< N {
			stbtt.MakeCodepointBitmap(&fontinfo, pixels, i32(w), i32(h), i32(w), scale.x, scale.y, CODEPOINT)
		}
		fmt.println("stb: ", time.since(start_time) / N)
		stbi.write_png("stb.png", i32(w), i32(h), 1, pixels, 0)
	}
}
