module base_io_module

  use bl_types

  implicit none

  private

  public :: write_base_state, read_base_state

contains

  subroutine write_base_state(state_name,w0_name,etarho_name,chk_name, &
                              rho0,rhoh0,p0, &
                              gamma1bar,w0,etarho,etarho_cc,div_etarho, &
                              div_coeff,psi,problo)
    
    use parallel
    use bl_prof_module
    use geometry, only : dr, r_start_coord, r_end_coord, numdisjointchunks
    use network, only: nspec
    use variables, only: rho_comp, rhoh_comp
    use bl_constants_module
    use probin_module, only: nlevs

    character(len=11), intent(in) :: state_name
    character(len=8) , intent(in) :: w0_name
    character(len=9) , intent(in) :: etarho_name
    character(len=8) , intent(in) :: chk_name
    real(kind=dp_t)  , intent(in) :: rho0(:,0:),rhoh0(:,0:)
    real(kind=dp_t)  , intent(in) :: p0(:,0:),gamma1bar(:,0:)
    real(kind=dp_t)  , intent(in) :: div_coeff(:,0:), psi(:,0:)
    real(kind=dp_t)  , intent(in) :: w0(:,0:)
    real(kind=dp_t)  , intent(in) :: etarho(:,0:),etarho_cc(:,0:), div_etarho(:,0:)

    real(kind=dp_t) :: base_r, problo
    character(len=20) :: out_name
    integer :: n, r, i

    type(bl_prof_timer), save :: bpt

    call build(bpt, "write_base_state")

    if (parallel_IOProcessor()) then

       print*,"chk_name",chk_name
       print*,"state_name",state_name

       ! write out the base state quantities
       out_name = chk_name // "/" // state_name
       write(6,*) 'Writing base state to ',out_name

       open(unit=99,file=out_name,form = "formatted", access = "sequential",action="write")

       do n=1,nlevs
          do i=1,numdisjointchunks(n)
             do r=r_start_coord(n,i),r_end_coord(n,i)
                base_r = problo + (dble(r)+HALF) * dr(n)
                write(99,1000)  base_r, rho0(n,r), p0(n,r), gamma1bar(n,r), &
                     rhoh0(n,r), div_coeff(n,r), &
                     psi(n,r), etarho_cc(n,r), div_etarho(n,r)
             end do
          end do
       end do
       close(99)

       ! write out w0 (it is edge-based, so it gets a separate file)
       out_name = chk_name // "/" // w0_name
       write(6,*) 'Writing w0 state to ',out_name
       write(6,*) ''

       open(unit=99,file=out_name,form = "formatted", access = "sequential",action="write")
       do n=1,nlevs
          do i=1,numdisjointchunks(n)
             do r=r_start_coord(n,i),r_end_coord(n,i)+1
                base_r = problo + dble(r) * dr(n)
                write(99,1000)  base_r,w0(n,r)
             end do
          end do
       end do
       close(99)

       ! write out etarho (it is edge-based, so it gets a separate file)
       out_name = chk_name // "/" // etarho_name
       write(6,*) 'Writing etarho on edges to ',out_name
       write(6,*) ''

       open(unit=99,file=out_name,form = "formatted", access = "sequential",action="write")
       do n=1,nlevs
          do i=1,numdisjointchunks(n)
             do r=r_start_coord(n,i),r_end_coord(n,i)+1
                base_r = problo + dble(r) * dr(n)
                write(99,1000)  base_r,etarho(n,r)
             end do
          end do
       end do
       close(99)

    endif

    call destroy(bpt)

1000 format(32(e30.20,1x))

  end subroutine write_base_state


  subroutine read_base_state(state_name,w0_name,etarho_name,chk_name, &
                             rho0,rhoh0,p0,gamma1bar,w0, &
                             etarho,etarho_cc,div_etarho, &
                             div_coeff,psi)

    use parallel
    use bl_prof_module
    use variables, only: rho_comp, rhoh_comp
    use network, only: nspec
    use geometry, only : dr, r_start_coord, r_end_coord, numdisjointchunks
    use bl_constants_module
    use restrict_base_module, only: fill_ghost_base
    use probin_module, only: nlevs
    
    character(len=11), intent(in   ) :: state_name
    character(len=8) , intent(in   ) :: w0_name
    character(len=9) , intent(in   ) :: etarho_name
    character(len=8) , intent(in   ) :: chk_name    
    real(kind=dp_t)  , intent(inout) :: rho0(:,0:),rhoh0(:,0:)
    real(kind=dp_t)  , intent(inout) :: p0(:,0:),gamma1bar(:,0:)
    real(kind=dp_t)  , intent(inout) :: div_coeff(:,0:), psi(:,0:)
    real(kind=dp_t)  , intent(inout) :: w0(:,0:)
    real(kind=dp_t)  , intent(inout) :: etarho(:,0:),etarho_cc(:,0:), div_etarho(:,0:)

    ! local
    real(kind=dp_t) :: r_dummy
    character(len=20) :: out_name
    integer :: r, n, i

    type(bl_prof_timer), save :: bpt

    call build(bpt, "read_base_state")

    ! read in the state variables
    out_name = chk_name // "/" // state_name
    if (parallel_IOProcessor()) then
      print *,'Reading base state from ',out_name
    end if

    open(unit=99,file=out_name)

    do n=1,nlevs
       do i=1,numdisjointchunks(n)
          do r=r_start_coord(n,i),r_end_coord(n,i)
             read(99,*)  r_dummy, rho0(n,r), p0(n,r), gamma1bar(n,r), &
                  rhoh0(n,r), div_coeff(n,r), psi(n,r), &
                  etarho_cc(n,r), div_etarho(n,r)
          end do
       end do
    end do
    close(99)

    ! read in w0
    out_name = chk_name // "/" // w0_name
    if (parallel_IOProcessor()) then
      print *,'Reading w0 state from ',out_name
    end if

    open(unit=99,file=out_name)
    do n=1,nlevs
       do i=1,numdisjointchunks(n)
          do r=r_start_coord(n,i),r_end_coord(n,i)+1
             read(99,*)  r_dummy, w0(n,r)
          end do
       end do
    end do
    close(99)

    ! read in etarho
    out_name = chk_name // "/" // etarho_name
    if (parallel_IOProcessor()) then
      print *,'Reading etarho state from ',out_name
    end if

    open(unit=99,file=out_name)
    do n=1,nlevs
       do i=1,numdisjointchunks(n)
          do r=r_start_coord(n,i),r_end_coord(n,i)+1
             read(99,*)  r_dummy, etarho(n,r)
          end do
       end do
    end do
    close(99)

    if (nlevs .gt. 1) then
       call fill_ghost_base(rho0,.true.)
       call fill_ghost_base(rhoh0,.true.)
       call fill_ghost_base(p0,.true.)
       call fill_ghost_base(gamma1bar,.true.)
       call fill_ghost_base(div_coeff,.true.)
       call fill_ghost_base(psi,.true.)
       call fill_ghost_base(etarho_cc,.true.)
       call fill_ghost_base(div_etarho,.true.)
       call fill_ghost_base(w0,.false.)
       call fill_ghost_base(etarho,.false.)
    end if

    ! calls to restrict base are not here needed since they are written to the checkpoint 
    ! file after a call to restrict base was already completed

    call destroy(bpt)

  end subroutine read_base_state

end module base_io_module

