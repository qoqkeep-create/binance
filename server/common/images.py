MAX_PLAN_IMAGES = 5
MAX_IMAGE_URL_LENGTH = 2_000_000


def validate_image_urls(value):
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValueError("图片必须是 URL 数组")
    if len(value) > MAX_PLAN_IMAGES:
        raise ValueError("最多上传 5 张图片")
    cleaned = []
    for image in value:
        if not isinstance(image, str) or not image.strip():
            raise ValueError("图片地址格式错误")
        image = image.strip()
        if not image.startswith(("https://", "http://", "data:image/")):
            raise ValueError("图片地址必须是 HTTP(S) 或图片 Data URL")
        if len(image) > MAX_IMAGE_URL_LENGTH:
            raise ValueError("单张图片不能超过 2 MB")
        cleaned.append(image)
    return cleaned