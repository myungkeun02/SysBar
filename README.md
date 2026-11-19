# SysBar

macOS 메뉴바에서 시스템 리소스를 확인하는 작은 앱입니다. Swift 단일 파일이며 외부 의존성이 없습니다.

## 기능

- **상태바**: CPU / 메모리 / 네트워크 / 디스크 / 배터리 중 고른 항목 하나를 고정 표시
- **팝오버 대시보드** (아이콘 클릭)
  - CPU 사용률 그래프 (사용자/시스템), 부하 평균
  - 메모리 사용률 그래프, 앱·와이어드·압축·스왑 내역
  - 네트워크 다운로드/업로드 그래프
  - 디스크·배터리 게이지
  - CPU 사용 상위 프로세스
  - 그래프는 2초 간격, 최근 3분
- 로그인 시 자동 실행 설정, 활성 상태 보기 바로가기

## 요구 사항

- macOS 13 이상
- Xcode 또는 Command Line Tools (`swiftc`)

## 빌드 & 설치

```bash
./build.sh
cp -R SysBar.app /Applications/
open /Applications/SysBar.app
```

## 로그인 시 자동 실행

팝오버의 ⚙️ 설정에서 켜거나, 터미널에서:

```bash
/Applications/SysBar.app/Contents/MacOS/SysBar --login on    # 켜기
/Applications/SysBar.app/Contents/MacOS/SysBar --login off   # 끄기
/Applications/SysBar.app/Contents/MacOS/SysBar --login status
```

## 팝오버 스냅샷

```bash
SysBar.app/Contents/MacOS/SysBar --snapshot out.png
```
