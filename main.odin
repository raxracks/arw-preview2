package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:text/i18n"
import "core:thread"
import "core:time"
import rl "vendor:raylib"

WIDTH :: 1280
HEIGHT :: 720
VERSION :: "version 1"

FONT_DATA :: #load("fonts/Inter/Inter-Regular.ttf")
FONT_SIZE :: 24
MOVEMENT_SPEED :: 50
ZOOM_SPEED :: 0.25
KEY_REPEAT_MILLIS :: 50

usage :: proc(programName: string) {
	fmt.println("Usage:", programName, "[OPTIONS] [.ARW file]")
	fmt.println("Preview Sony a6000 .ARW files")
	fmt.println("")
	fmt.println("      --verbose output ")
	fmt.println("  -v, --version output version information and exit")
}

ParseError :: enum {
	None = 0,
	TooSmallData,
	MissingHeader,
	InvalidValueOffset,
	InvalidIFDOffset,
	NoPreviewImage,
}

read_u16 :: proc(data: ^[]u8, pos: u32) -> (res: u16, success: bool) {
	if int(pos) + 1 >= len(data) {
		return 0, false
	}

	#no_bounds_check { 	// Just for fun
		return u16(data[pos]) | u16(data[pos + 1]) << 8, true
	}
}

read_u32 :: proc(data: ^[]u8, pos: u32) -> (res: u32, success: bool) {
	if int(pos) + 3 >= len(data) {
		return 0, false
	}

	#no_bounds_check { 	// Just for fun
		return u32(data[pos]) |
			u32(data[pos + 1]) << 8 |
			u32(data[pos + 2]) << 16 |
			u32(data[pos + 3]) << 24,
			true
	}
}

get_jpeg_image_preview_from_arw_data :: proc(
	data: ^[]u8,
) -> (
	previewImageStart, previewImageLength: u32,
	err: ParseError,
) {
	previewImageStart = 0
	previewImageLength = 0
	err = .TooSmallData

	if len(data) < 8 {
		return
	}

	if mem.compare(data[:4], {'I', 'I', 0x2a, 0x00}) != 0 {
		return 0, 0, .MissingHeader
	}

	firstIFDOffset, firstIFDOffsetSuccess := read_u32(data, 4)
	if !firstIFDOffsetSuccess do return

	if firstIFDOffset == 0 || firstIFDOffset % 2 != 0 {
		return 0, 0, .InvalidIFDOffset
	}

	numDirEntries, numDirEntriesSuccess := read_u16(data, firstIFDOffset)
	if !numDirEntriesSuccess do return

	for i: u16 = 0; i < numDirEntries; i += 1 {
		offset := firstIFDOffset + 2 + u32(i * 12)

		tag, tagSuccess := read_u16(data, offset)
		if !tagSuccess do return

		type, typeSuccess := read_u16(data, offset + 2)
		if !typeSuccess do return

		valueOffset, valueOffsetSuccess := read_u32(data, offset + 8)
		if !valueOffsetSuccess do return

		valueOffsetIsValue := type != 5

		if valueOffsetIsValue {
			if tag == 0x0201 {
				previewImageStart = valueOffset
			} else if tag == 0x0202 {
				previewImageLength = valueOffset
				return previewImageStart, previewImageLength, .None
			}
		} else {
			if valueOffset % 2 != 0 {
				return 0, 0, .InvalidValueOffset
			}
		}
	}

	return 0, 0, .NoPreviewImage
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	if len(os.args) < 2 {
		usage(os.args[0])
		os.exit(0)
	}

	filename: string

	hasVerboseFlag := false
	hasVersionFlag := false
	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		if arg == "-v" || arg == "--version" {
			hasVersionFlag = true
		} else if arg == "--verbose" {
			hasVerboseFlag = true
		} else {
			filename = arg
		}
	}

	if hasVersionFlag {
		fmt.println("arw-preview2", VERSION)
		os.exit(0)
	}

	if filename == "" {
		usage(os.args[0])
		os.exit(0)
	}

	if !hasVerboseFlag {
		rl.SetTraceLogLevel(.ERROR)
	}

	maybe_image: Maybe(rl.Image)
	thread.create_and_start_with_poly_data3(
		&maybe_image,
		hasVerboseFlag,
		filename,
		proc(maybe_image: ^Maybe(rl.Image), hasVerboseFlag: bool, filename: string) {
			data, success := os.read_entire_file_from_filename(filename)
			if !success {
				fmt.println("Failed to read file:", filename)
				os.exit(1)
			}
			defer delete(data)


			previewImageStart, previewImageLength, err := get_jpeg_image_preview_from_arw_data(
				&data,
			)
			switch err {
			case .None:
			case .TooSmallData:
				fmt.println("Too small file")
				os.exit(1)
			case .MissingHeader:
				fmt.println("Missing header, not a little-endian TIFF file")
				os.exit(1)
			case .InvalidIFDOffset:
				fmt.println("Found an IFD offset not beginning on a word boundary, or zero")
				os.exit(1)
			case .InvalidValueOffset:
				fmt.println("Invalid value offset. Found a value not beginning on a word boundary")
				os.exit(1)
			case .NoPreviewImage:
				fmt.println("No preview image found!")
				os.exit(1)
			}

			if hasVerboseFlag {
				fmt.print("\x1b[1;32m")
				fmt.println("preview image start  :", previewImageStart)
				fmt.println("preview image length :", previewImageLength)
				fmt.print("\x1b[0m")
			}

			maybe_image^ = rl.LoadImageFromMemory(
				".jpg",
				&data[previewImageStart],
				i32(previewImageLength),
			)
		},
	)

	texture: rl.Texture

	// .VSYNC_HINT slows down my computer when focusing other windows for some reason
	// So I just manually SetTargetFPS() to the monitor refresh rate
	rl.SetConfigFlags({.WINDOW_RESIZABLE})
	rl.InitWindow(WIDTH, HEIGHT, "arw-preview2")
	defer rl.CloseWindow()
	rl.SetTargetFPS(rl.GetMonitorRefreshRate(rl.GetCurrentMonitor()))

	theFont := rl.LoadFontFromMemory(
		".ttf",
		raw_data(FONT_DATA),
		i32(len(FONT_DATA)),
		FONT_SIZE,
		nil,
		0,
	)

	camera: rl.Camera2D
	camera.zoom = 1.0
	fpsTextStringBuilder := strings.builder_make()
	fpsTextEnabled := false
	defer strings.builder_destroy(&fpsTextStringBuilder)

	hasResized := false

	keyPressRepeatTime := time.now()
	start := time.now()

	for !rl.WindowShouldClose() {
		if image, ok := maybe_image.?; ok {
			texture = rl.LoadTextureFromImage(image)
			rl.UnloadImage(image)
			maybe_image = nil
		}

		// raylib doesn't respect my keybinds, so force it to also close on caps lock
		if rl.IsKeyDown(.Q) || rl.IsKeyDown(.CAPS_LOCK) {
			break
		}

		if rl.IsMouseButtonDown(.LEFT) ||
		   rl.IsMouseButtonDown(.RIGHT) ||
		   rl.IsMouseButtonDown(.MIDDLE) {
			rl.SetMouseCursor(.RESIZE_ALL)
			delta := rl.GetMouseDelta()
			delta = delta * (-1.0 / camera.zoom)
			camera.target += delta
		} else {
			rl.SetMouseCursor(.DEFAULT)
		}

		wheel := rl.GetMouseWheelMove()
		if wheel != 0 {
			mouseWorldPos := rl.GetScreenToWorld2D(rl.GetMousePosition(), camera)
			camera.offset = rl.GetMousePosition()
			camera.target = mouseWorldPos
			scaleFactor := 1.0 + (ZOOM_SPEED * abs(wheel))
			if wheel < 0 do scaleFactor = 1.0 / scaleFactor
			camera.zoom *= scaleFactor
		}

		firstResize := false
		if rl.IsWindowResized() {
			camera.offset = {f32(rl.GetScreenWidth()) / 2, f32(rl.GetScreenHeight()) / 2}
			if !hasResized {
				hasResized = true
				firstResize = true
			}
		}


		// Fit the image size to the screen
		// We also do this on the first resize event within 60ms of startup, because Linux window managers...
		if (firstResize && time.since(start) < 60 * time.Millisecond) ||
		   rl.IsGestureDetected(.DOUBLETAP) ||
		   rl.IsKeyPressed(.ENTER) ||
		   rl.IsKeyPressed(.SPACE) {
			screenWidth := f32(rl.GetScreenWidth())
			screenHeight := f32(rl.GetScreenHeight())

			textureWidth := f32(texture.width)
			textureHeight := f32(texture.height)

			camera.zoom = min(screenWidth / textureWidth, screenHeight / textureHeight)
			camera.offset = {screenWidth / 2, screenHeight / 2}
			camera.target = {textureWidth / 2, textureHeight / 2}
			firstResize = false
		}

		isCtrlDown := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
		didZoom := false
		allowKeyRepeat := time.since(keyPressRepeatTime) > KEY_REPEAT_MILLIS * time.Millisecond
		if allowKeyRepeat {
			keyPressRepeatTime = time.now()

			left, right, up, down := false, false, false, false
			left |= rl.IsKeyDown(.A)
			right |= rl.IsKeyDown(.D)
			up |= rl.IsKeyDown(.W)
			down |= rl.IsKeyDown(.S)

			if isCtrlDown {
				left |= rl.IsKeyDown(.LEFT)
				right |= rl.IsKeyDown(.RIGHT)
				up |= rl.IsKeyDown(.UP)
				down |= rl.IsKeyDown(.DOWN)
			} else {
				if rl.IsKeyDown(.UP) {
					didZoom = true
					camera.zoom *= 1 + ZOOM_SPEED
				} else if rl.IsKeyDown(.DOWN) {
					didZoom = true
					camera.zoom *= 1.0 / (1 + ZOOM_SPEED)
				}
			}

			movementVector := [2]f32 {
				f32(int(right)) - f32(int(left)),
				f32(int(down)) - f32(int(up)),
			}
			camera.target += movementVector * (MOVEMENT_SPEED / camera.zoom)
		}

		if !didZoom {
			charPressed := rl.GetCharPressed()
			if charPressed == '+' do camera.zoom *= 1 + ZOOM_SPEED
			else if charPressed == '-' do camera.zoom *= 1.0 / (1 + ZOOM_SPEED)
		}

		if rl.IsKeyPressed(.LEFT_SHIFT) || rl.IsKeyPressed(.RIGHT_SHIFT) {
			fpsTextEnabled = !fpsTextEnabled
		}

		camera.zoom = min(10_000, camera.zoom)
		camera.zoom = max(0.01, camera.zoom)

		rl.BeginDrawing()
		rl.BeginMode2D(camera)
		rl.ClearBackground({53, 53, 53, 255})
		rl.DrawTexture(texture, 0, 0, rl.WHITE)

		if camera.zoom > 13 {
			draw_grid(texture.width, texture.height, {255, 255, 255, 40})
		}
		rl.EndMode2D()

		if fpsTextEnabled {
			buf: [16]byte
			fpsText := strconv.itoa(buf[:], int(rl.GetFPS()))
			strings.write_string(&fpsTextStringBuilder, fpsText)
			strings.write_string(&fpsTextStringBuilder, " fps")
			rl.DrawTextEx(
				theFont,
				strings.to_cstring(&fpsTextStringBuilder),
				{5, 5},
				FONT_SIZE,
				0,
				{0, 255, 0, 255},
			)
			strings.builder_reset(&fpsTextStringBuilder)
		}

		rl.EndDrawing()

		//fmt.println(track.total_memory_allocated)
	}
}
