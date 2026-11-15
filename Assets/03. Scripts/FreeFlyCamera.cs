using UnityEngine;
using UnityEngine.InputSystem;

/// <summary>
/// Play 모드에서 셰이더를 둘러보기 위한 자유 비행 카메라 (새 Input System 사용).
/// - 마우스 우클릭을 누른 채 끌기: 시점 회전
/// - W/A/S/D: 앞/왼쪽/뒤/오른쪽, E/Q: 위/아래
/// - Shift: 빠르게 이동, 마우스 휠: 이동 속도 조절
/// </summary>
public class FreeFlyCamera : MonoBehaviour
{
    [SerializeField] private float moveSpeed = 2f;
    [SerializeField] private float lookSensitivity = 0.15f;
    [SerializeField] private float fastMultiplier = 3f;
    [SerializeField] private float minSpeed = 0.2f;
    [SerializeField] private float maxSpeed = 20f;

    private float yaw;
    private float pitch;

    private void OnEnable()
    {
        Vector3 euler = transform.eulerAngles;
        yaw = euler.y;
        pitch = euler.x > 180f ? euler.x - 360f : euler.x;
    }

    private void Update()
    {
        Keyboard keyboard = Keyboard.current;
        Mouse mouse = Mouse.current;
        if (keyboard == null || mouse == null) return;

        // 시점 회전: 우클릭을 누르고 있는 동안만
        bool looking = mouse.rightButton.isPressed;
        Cursor.lockState = looking ? CursorLockMode.Locked : CursorLockMode.None;
        Cursor.visible = !looking;
        if (looking)
        {
            Vector2 delta = mouse.delta.ReadValue();
            yaw += delta.x * lookSensitivity;
            pitch = Mathf.Clamp(pitch - delta.y * lookSensitivity, -89f, 89f);
            transform.rotation = Quaternion.Euler(pitch, yaw, 0f);
        }

        // 휠: 이동 속도 조절 (한 칸에 1.2배)
        float scroll = mouse.scroll.ReadValue().y;
        if (scroll > 0f) moveSpeed = Mathf.Min(moveSpeed * 1.2f, maxSpeed);
        else if (scroll < 0f) moveSpeed = Mathf.Max(moveSpeed / 1.2f, minSpeed);

        // 이동
        Vector3 dir = Vector3.zero;
        if (keyboard.wKey.isPressed) dir += transform.forward;
        if (keyboard.sKey.isPressed) dir -= transform.forward;
        if (keyboard.dKey.isPressed) dir += transform.right;
        if (keyboard.aKey.isPressed) dir -= transform.right;
        if (keyboard.eKey.isPressed) dir += Vector3.up;
        if (keyboard.qKey.isPressed) dir -= Vector3.up;

        float speed = moveSpeed * (keyboard.leftShiftKey.isPressed ? fastMultiplier : 1f);
        transform.position += dir.normalized * speed * Time.deltaTime;
    }

    private void OnDisable()
    {
        Cursor.lockState = CursorLockMode.None;
        Cursor.visible = true;
    }
}
