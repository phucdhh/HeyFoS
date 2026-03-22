def update_pyblend():
    with open("Sources/HeyFoSCore/Processing/PyBlend.swift", "r") as f:
        text = f.read()

    # Increase dilation kernel size
    old_dilate = """let dilated = try dilateTexture(focusMap, kernelSize: 15)"""
    new_dilate = """let dilated = try dilateTexture(focusMap, kernelSize: 25)"""
    text = text.replace(old_dilate, new_dilate)

    # Increase blur to match the bigger dilation (prevent jagged edges)
    old_blur = """let blurred = try gaussianBlur(dilated, radius: 3.0)"""
    new_blur = """let blurred = try gaussianBlur(dilated, radius: 5.0)"""
    text = text.replace(old_blur, new_blur)

    # Increase exponent to make it closer to winner-takes-all, completely killing small focus responses
    old_exp = "var exponentParam: Float = 4.0"
    new_exp = "var exponentParam: Float = 12.0"
    text = text.replace(old_exp, new_exp)

    # We can also add a minimum threshold in the shader
    old_shader = """float val = input.read(gid).r;
            float sharpened = pow(max(val, 0.0001f), exponent);"""
    new_shader = """float val = input.read(gid).r;
            // Add a small threshold to completely kill noise floor
            if (val < 0.01f) { val = 0.0f; }
            float sharpened = pow(max(val, 0.000001f), exponent);"""
    text = text.replace(old_shader, new_shader)

    with open("Sources/HeyFoSCore/Processing/PyBlend.swift", "w") as f:
        f.write(text)

    print("Updated PyBlend.swift")

if __name__ == "__main__":
    update_pyblend()
