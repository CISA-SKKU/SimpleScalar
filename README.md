# SimpleScalar

SimpleScalar의 out-of-order 시뮬레이터(**simplescalar/sim-outorder.c**)를 여러 프로그램을 동시에 실행하는 SMT(Simultaneous Multithreading) 시뮬레이터로 확장합니다.

## 빌드

```bash
cd simplescalar
make sim-outorder
```

## 실행

레포 루트에서 **run.sh**를 사용합니다.

```bash
chmod +x run.sh   # 실행 권한이 없는 경우
./run.sh <num_threads> <config_file> <workload_1> ... <workload_N>

./run.sh 1 example.cfg bzip2
./run.sh 2 example.cfg bzip2 mcf
```

- workload: `bzip2 | gcc | gromacs | mcf` (**spec_alpha/** 의 Alpha 바이너리)
- config 파일은 **simplescalar/config/** 에서 찾습니다. 필요한 config 파일은 직접 작성해야 합니다.
- 워크로드가 둘 이상이면 run.sh는 각 프로그램의 명령줄을 구분자 `--`로 이어 붙여 sim-outorder에 전달합니다.

## 구현 가이드

SMT를 구현하면서 반드시 살펴봐야 하는 코드 위치입니다. 설계(정적/동적 분할, fetch policy 등)는 자유롭게 선택하면 됩니다.

### 1. 프로그램 입력과 로드
- 시뮬레이터는 `--`를 해석하지 않습니다. **main.c**에서 옵션 파싱이 끝난 위치(*exec_index*)부터 argv 끝까지가 통째로 첫 번째 프로그램의 인자로 *sim_load_prog()* (**sim-outorder.c**)에 전달됩니다. 이 구간을 프로그램별로 나누어 각각 로드하는 코드를 추가해야 합니다.  
	- 구분자를 `--` 대신 다른 방식으로 정해도 되지만, 그 경우 run.sh도 맞게 수정하세요.
- *ld_load_prog()* (**loader.c**)는 regs/mem을 인자로 받지만, 로드된 프로그램의 세그먼트 정보(*ld_text_base*, *ld_brk_point*, *ld_prog_entry* 등)는 전역 변수에 저장됩니다. 두 번째 프로그램을 로드하면 이 값들이 어떻게 되는지 확인하세요.  
	- 이 전역 변수들은 로드 이후에도 계속 사용됩니다. *MD_VALID_ADDR()* (**alpha.h**)는 이 값으로 주소가 프로그램 구간 안에 있는지 판단하고, **syscall.c**의 brk/mmap은 이 값을 힙/mmap 영역의 현재 위치로 사용합니다.

### 2. 스레드별 상태
- 각 스레드는 독립적인 architectural state가 필요합니다.  
	- 레지스터 파일: *struct regs_t*
	- 메모리: *struct mem_t*
- sim-outorder는 분기 예측이 틀린 경로의 명령어도 실행합니다(mis-speculation). 이때 바뀐 레지스터/메모리 값은 별도의 그림자(shadow) 상태에 기록되고, 예측 실패가 확인되면 버려집니다. 이 그림자 상태도 전부 전역 변수이므로, 한 스레드의 복구가 다른 스레드의 상태를 건드리지 않아야 합니다.  
	- *spec_mode*, *recover_PC*
	- *spec_regs_R / F / C*, *use_spec_R / F / C*
	- *store_htable* (*spec_mem_access()* 가 사용)
	- 복구 흐름: *ruu_writeback()* → *ruu_recover()*, *tracer_recover()*, *bpred_recover()*

### 3. Fetch
- fetch 단계의 상태(*fetch_regs_PC*, *fetch_pred_PC*, IFQ인 *fetch_data*)도 전역입니다.  
- I-cache miss가 나면 *ruu_fetch_issue_delay* 로 fetch 단계 **전체**가 멈춥니다. SMT에서 이것이 적절한지 생각해 보세요.  
- 어느 스레드에서 fetch할지 정하는 정책(fetch policy)은 *ruu_fetch()* 에서 구현하게 됩니다.

### 4. RUU와 레지스터 리네이밍
- SimpleScalar의 리네이밍 로직은 ROB 기반과 유사하며, *struct RUU_station* 이 ROB 역할을 합니다. RUU는 reservation station과 ROB를 합친 SimpleScalar의 단위입니다.  
- RUU 엔트리는 스레드별로 구분되어야 합니다. 정적 분할과 동적 공유 중 선택할 수 있습니다.  
- 리네이밍(의존성 추적)에는 아래 변수가 사용됩니다.  
	- *use_spec_cv*
	- *create_vector*, *spec_create_vector*
	- *create_vector_rt*, *spec_create_vector_rt*

### 5. LSQ
- *lsq_refresh()* 와 *ruu_issue()* 는 load/store 사이의 메모리 의존성을 **주소 비교**로 판단합니다. 서로 다른 스레드가 같은 가상 주소를 쓰는 경우를 생각해 보세요.

### 6. 캐시와 분기 예측기
- 캐시(I-cache, D-cache, TLB)와 분기 예측기(BTB, RAS)는 모두 가상 주소로 동작합니다. 스레드가 다르면 같은 가상 주소라도 다른 메모리이므로, 각 엔트리가 어느 스레드의 것인지 구분해야 합니다.  
	- I-Cache, D-Cache, TLB: **cache.c**
	- Branch Predictor(BTB, RAS): **bpred.c**

### 7. 시스템 콜과 종료 조건
- 시스템 콜(*F_TRAP*)은 *ruu_dispatch()* 에서 RUU가 완전히 빌 때까지 기다린 뒤 실행됩니다.  
- *program_complete* 는 전역 플래그 하나이고, *exit* 시스템 콜(**syscall.c**)은 *longjmp* 로 시뮬레이터 전체를 종료합니다. 한 스레드가 먼저 끝났을 때 시뮬레이션을 어떻게 이어갈지 정의해야 합니다.  
- *sim_num_insn*, *max_insts* 는 모든 스레드의 합입니다. 스레드별 통계가 필요한지 고려하세요.

### 8. sim_main()
- 시뮬레이션 루프는 **sim-outorder.c**의 *sim_main()* 에 있습니다. 매 사이클 파이프라인 스테이지를 역순(commit → writeback → lsq_refresh → issue → dispatch → fetch)으로 호출합니다.  
	- 루프 시작부에 RUU/LSQ의 head/tail/num 정합성을 검사하는 sanity check가 있습니다. RUU 구조를 바꾸면 이 검사부터 맞게 고쳐야 합니다.
	- fast-forward 구간도 전역 regs/mem으로 실행됩니다.
