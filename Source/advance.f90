module advance_timestep_module

  use probin_module
    
  implicit none

  private

  public :: advance_timestep

contains
    
  subroutine advance_timestep(init_mode,mla,uold,sold,unew,snew, &
                              gpres,pres,normal,s0_old, &
                              s0_new,p0_old,p0_new,gam1,w0, &
                              rho_omegadot2,div_coeff_old,div_coeff_new, &
                              grav_cell_old,dx,time,dt,dtold,the_bc_tower, &
                              dSdt,Source_old,Source_new, sponge,hgrhs,istep)

    use bl_prof_module
    use ml_layout_module
    use bl_constants_module
    use multifab_module
    use pre_advance_module
    use velocity_advance_module
    use scalar_advance_module
    use macrhs_module
    use macproject_module
    use hgrhs_module
    use hgproject_module
    use proj_parameters
    use bc_module
    use box_util_module
    use make_div_coeff_module
    use make_w0_module
    use advect_base_module
    use react_base_module
    use react_state_module
    use make_S_module
    use average_module
    use phihalf_module
    use extraphalf_module
    use thermal_conduct_module
    use make_explicit_thermal_module
    use add_react_to_thermal_module
    use variables, only: nscal, press_comp, temp_comp, rho_comp
    use geometry, only: nr, spherical
    use network, only: nspec
    use make_grav_module
    use fill_3d_module
    use cell_to_edge_module
    use define_bc_module
    use probin_module, only: verbose
    
    logical,         intent(in   ) :: init_mode
    type(ml_layout), intent(inout) :: mla
    type(multifab),  intent(in   ) :: uold(:)
    type(multifab),  intent(in   ) :: sold(:)
    type(multifab),  intent(inout) :: unew(:)
    type(multifab),  intent(inout) :: snew(:)
    type(multifab),  intent(inout) :: gpres(:)
    type(multifab),  intent(inout) :: pres(:)
    type(multifab),  intent(in   ) :: normal(:)
    real(dp_t)    ,  intent(inout) :: s0_old(:,0:,:)
    real(dp_t)    ,  intent(inout) :: s0_new(:,0:,:)
    real(dp_t)    ,  intent(inout) :: p0_old(:,0:)
    real(dp_t)    ,  intent(inout) :: p0_new(:,0:)
    real(dp_t)    ,  intent(inout) :: gam1(:,0:)
    real(dp_t)    ,  intent(inout) :: w0(:,0:)
    type(multifab),  intent(inout) :: rho_omegadot2(:)
    real(dp_t)    ,  intent(in   ) :: div_coeff_old(:,0:)
    real(dp_t)    ,  intent(inout) :: div_coeff_new(:,0:)
    real(dp_t)    ,  intent(in   ) :: grav_cell_old(:,0:)
    real(dp_t)    ,  intent(in   ) :: dx(:,:),time,dt,dtold
    type(bc_tower),  intent(in   ) :: the_bc_tower
    type(multifab),  intent(inout) :: dSdt(:)
    type(multifab),  intent(inout) :: Source_old(:)
    type(multifab),  intent(inout) :: Source_new(:)
    type(multifab),  intent(in   ) :: sponge(:)
    type(multifab),  intent(inout) :: hgrhs(:)
    integer       ,  intent(in   ) :: istep

    ! local
    type(multifab), allocatable :: rhohalf(:)
    type(multifab), allocatable :: w0_cart_vec(:)
    type(multifab), allocatable :: w0_force_cart_vec(:)
    type(multifab), allocatable :: macrhs(:)
    type(multifab), allocatable :: macphi(:)
    type(multifab), allocatable :: hgrhs_old(:)
    type(multifab), allocatable :: Source_nph(:)
    type(multifab), allocatable :: thermal(:)
    type(multifab), allocatable :: s2star(:)
    type(multifab), allocatable :: rho_omegadot2_hold(:)
    type(multifab), allocatable :: s1(:)
    type(multifab), allocatable :: s2(:)
    type(multifab), allocatable :: gamma1_term(:)
    type(multifab), allocatable :: rho_omegadot1(:)
    type(multifab), allocatable :: rho_Hext(:)
    type(multifab), allocatable :: div_coeff_3d(:) ! Only needed for spherical.eq.1

    type(multifab), allocatable :: umac(:,:)
    type(multifab), allocatable :: utrans(:,:)
    
    logical       , allocatable :: umac_nodal_flag(:)

    real(dp_t)    , allocatable :: grav_cell_nph(:,:)
    real(dp_t)    , allocatable :: grav_cell_new(:,:)
    real(dp_t)    , allocatable :: s0_nph(:,:,:)
    real(dp_t)    , allocatable :: w0_force(:,:)
    real(dp_t)    , allocatable :: w0_old(:,:)
    real(dp_t)    , allocatable :: Sbar(:,:,:)
    real(dp_t)    , allocatable :: div_coeff_nph(:,:)
    real(dp_t)    , allocatable :: div_coeff_edge(:,:)
    real(dp_t)    , allocatable :: rho_omegadotbar1(:,:,:)
    real(dp_t)    , allocatable :: rho_omegadotbar2(:,:,:)
    real(dp_t)    , allocatable :: rho_Hextbar(:,:,:)
    real(dp_t)    , allocatable :: eta(:,:,:)
    real(dp_t)    , allocatable :: s0_1(:,:,:)
    real(dp_t)    , allocatable :: s0_2(:,:,:)
    real(dp_t)    , allocatable :: p0_1(:,:)
    real(dp_t)    , allocatable :: p0_2(:,:)

    integer       , allocatable :: lo(:),hi(:)

    real(dp_t)                :: halfdt,eps_in
    integer                   :: j,n,dm,comp,nlevs,ng_s,proj_type
    logical                   :: nodal(mla%dim)
    type(bl_prof_timer), save :: bpt

    call build(bpt, "advance_timestep")

    dm = mla%dim
    nlevs = size(uold)

    allocate(           rhohalf(nlevs))
    allocate(       w0_cart_vec(nlevs))   
    allocate( w0_force_cart_vec(nlevs))    
    allocate(            macrhs(nlevs))
    allocate(            macphi(nlevs))
    allocate(         hgrhs_old(nlevs))
    allocate(        Source_nph(nlevs))
    allocate(           thermal(nlevs))
    allocate(            s2star(nlevs))
    allocate(rho_omegadot2_hold(nlevs))
    allocate(                s1(nlevs))
    allocate(                s2(nlevs))
    allocate(       gamma1_term(nlevs))
    allocate(     rho_omegadot1(nlevs))
    allocate(          rho_Hext(nlevs))
    allocate(      div_coeff_3d(nlevs))
    
    allocate(  umac(nlevs,dm))
    allocate(utrans(nlevs,dm))

    allocate(umac_nodal_flag(dm))

    allocate(   grav_cell_nph(nlevs,0:nr(nlevs)-1))
    allocate(   grav_cell_new(nlevs,0:nr(nlevs)-1))
    allocate(          s0_nph(nlevs,0:nr(nlevs)-1,nscal))
    allocate(        w0_force(nlevs,0:nr(nlevs)-1))
    allocate(          w0_old(nlevs,0:nr(nlevs)  ))
    allocate(            Sbar(nlevs,0:nr(nlevs)-1,1    ))
    allocate(   div_coeff_nph(nlevs,0:nr(nlevs)-1))
    allocate(  div_coeff_edge(nlevs,0:nr(nlevs)  ))
    allocate(rho_omegadotbar1(nlevs,0:nr(nlevs)-1,nspec))
    allocate(rho_omegadotbar2(nlevs,0:nr(nlevs)-1,nspec))
    allocate(     rho_Hextbar(nlevs,0:nr(nlevs)-1,1))
    allocate(             eta(nlevs,0:nr(nlevs)  ,nscal))
    allocate(            s0_1(nlevs,0:nr(nlevs)-1,nscal))
    allocate(            s0_2(nlevs,0:nr(nlevs)-1,nscal))
    allocate(            p0_1(nlevs,0:nr(nlevs)-1))
    allocate(            p0_2(nlevs,0:nr(nlevs)-1))

    allocate(lo(dm))
    allocate(hi(dm))
    
    ! This is always zero at the beginning of a time step
    eta(:,:,:) = ZERO

    ! Set these to be safe
    s0_1(:,:,:) = ZERO
    s0_2(:,:,:) = ZERO
    p0_1(:,:)   = ZERO
    p0_2(:,:)   = ZERO

    ! Set w0_old to w0 from last time step.
    w0_old = w0

    nodal = .true.
    ng_s = sold(1)%ng
    halfdt = half*dt

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 1 -- define average expansion at time n+1/2
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    
    if (parallel_IOProcessor() .and. verbose .ge. 1) then
       write(6,*) '<<< CALLING advance_timestep with dt =',dt 
       write(6,*) '<<< STEP  1 : make w0 >>> '
    end if
    
    do n=1,nlevs
       call multifab_build(Source_nph(n), mla%la(n), 1, 0)
    end do

    if (init_mode) then
       call make_S_at_halftime(nlevs,Source_nph,Source_old,Source_new)
    else
       call extrap_to_halftime(nlevs,Source_nph,dSdt,Source_old,dt)
    end if
    
    call average(mla,Source_nph,Sbar,dx,1,1)
    
    call make_w0(nlevs,w0,w0_old,w0_force,Sbar(:,:,1),p0_old, &
                 s0_old(:,:,rho_comp),gam1,eta,dt,dtold)
    
    if (dm .eq. 3) then
       do n=1,nlevs
          call multifab_build(w0_cart_vec(n), mla%la(n), dm, 1)
       end do

       call make_w0_cart(nlevs,w0,w0_cart_vec,normal,dx) 
    end if
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 2 -- construct the advective velocity
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    
    if (parallel_IOProcessor() .and. verbose .ge. 1) then
       write(6,*) '<<< STEP  2 : create MAC velocities>>> '
    end if

    do n=1,nlevs
       do comp=1,dm
          umac_nodal_flag = .false.
          umac_nodal_flag(comp) = .true.
          call multifab_build(  umac(n,comp), mla%la(n),  1, 1, nodal = umac_nodal_flag)
          call multifab_build(utrans(n,comp), mla%la(n),  1, 1, nodal = umac_nodal_flag)
       end do
    end do
    
    call advance_premac(nlevs,uold,sold,umac,utrans,gpres,normal,w0,w0_cart_vec, &
                        s0_old,grav_cell_old,dx,dt,the_bc_tower%bc_tower_array,mla)

    do n=1,nlevs
       call multifab_build(gamma1_term(n), mla%la(n), 1, 0)
       call multifab_build(macrhs(n),      mla%la(n), 1, 0)
       call setval(gamma1_term(n), ZERO, all=.true.)
    end do

    call make_macrhs(nlevs,macrhs,Source_nph,gamma1_term,Sbar(:,:,1),div_coeff_old,dx)

    do n=1,nlevs
       call destroy(gamma1_term(n))
       call destroy(Source_nph(n))
    end do

    do n=1,nlevs
       call multifab_build(macphi(n), mla%la(n), 1, 1)
       call setval(macphi(n), ZERO, all=.true.)
    end do

    ! MAC projection !
    if (spherical .eq. 1) then
       do n=1,nlevs
          call multifab_build(div_coeff_3d(n), mla%la(nlevs), 1, 1)
       end do

       call fill_3d_data_wrapper(nlevs,div_coeff_3d,div_coeff_old,dx)
       call macproject(mla,umac,macphi,sold,dx,the_bc_tower, &
                       press_comp, macrhs,div_coeff_3d=div_coeff_3d)

       do n=1,nlevs
          call destroy(div_coeff_3d(n))
       end do
    else
       do n=1,nlevs
          call cell_to_edge(n,div_coeff_old(n,:),div_coeff_edge(n,:))
       end do
       call macproject(mla,umac,macphi,sold,dx,the_bc_tower, &
                       press_comp, macrhs,div_coeff_1d=div_coeff_old, &
                       div_coeff_half_1d=div_coeff_edge)
    end if

    if(do_half_alg) then
       do n=1,nlevs
          call destroy(macphi(n))
       end do
    end if

    do n=1,nlevs
       call destroy(macrhs(n))
    end do
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 3 -- react the full state and then base state through dt/2
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    if (parallel_IOProcessor() .and. verbose .ge. 1) then
       write(6,*) '<<< STEP  3 : react state     '
       write(6,*) '            : react  base >>> '
    end if

    do n=1,nlevs
       call multifab_build(s1(n),            mla%la(n), nscal, ng_s)
       call multifab_build(rho_omegadot1(n), mla%la(n), nspec, 0)
       call multifab_build(rho_Hext(n),      mla%la(n), 1,     0)
    end do

    call react_state(nlevs,mla,sold,s1,rho_omegadot1,rho_Hext,halfdt,dx, &
                     the_bc_tower%bc_tower_array,time)
    
    call average(mla,rho_omegadot1,rho_omegadotbar1,dx,1,nspec)
    call average(mla,rho_Hext,rho_Hextbar,dx,1,1)
    if (evolve_base_state) then
       call react_base(nlevs,p0_old,s0_old,rho_omegadotbar1,rho_Hextbar(:,:,1),halfdt, &
                       p0_1,s0_1,gam1)
    else
       p0_1 = p0_old
       s0_1 = s0_old
    end if

    do n=1,nlevs
       call destroy(rho_Hext(n))
    end do

    do n=1,nlevs
       call make_grav_cell(n,grav_cell_new(n,:),s0_1(n,:,rho_comp))
       call make_div_coeff(n,div_coeff_new(n,:),s0_1(n,:,rho_comp),p0_1(n,:), &
                           gam1(n,:),grav_cell_new(n,:))
    end do
    
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 4 -- advect the base state and full state through dt
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    if (parallel_IOProcessor() .and. verbose .ge. 1) then
       write(6,*) '<<< STEP  4 : advect base        '
       write(6,*) '            : scalar_advance >>> '
    end if
    
    if (evolve_base_state) then
       call advect_base(nlevs,w0,Sbar,p0_1,p0_2,s0_1,s0_2,gam1,div_coeff_new,eta, &
                        dx(:,dm),dt)
    else
       p0_2 = p0_1
       s0_2 = s0_1
    end if

    do n=1,nlevs
       call multifab_build(thermal(n), mla%la(n), 1, 1)
    end do
    
    if(use_thermal_diffusion) then
       call make_explicit_thermal(mla,dx,thermal,s1,p0_1, &
                                  the_bc_tower,temp_diffusion_formulation)
    else
       do n=1,nlevs
          call setval(thermal(n),ZERO,all=.true.)
       end do
    end if
    
    ! thermal is the temperature forcing if we use the temperature godunov predictor
    ! so we add the reaction terms to thermal
    if(istep .le. 1) then
       call add_react_to_thermal(nlevs,thermal,rho_omegadot1,s1, &
                                 the_bc_tower%bc_tower_array,mla,dx)
    else
       call add_react_to_thermal(nlevs,thermal,rho_omegadot2,s1, &
                                 the_bc_tower%bc_tower_array,mla,dx)

       if(.not. do_half_alg) then
          do n=1,nlevs
             call multifab_build(rho_omegadot2_hold(n), mla%la(n), nspec, 0)
             call multifab_copy_c(rho_omegadot2_hold(n),1,rho_omegadot2(n),1,3,0)
          end do
       end if
    end if
            
    if(do_half_alg) then
       do n=1,nlevs
          call destroy(rho_omegadot1(n))
       end do
    end if

    do n=1,nlevs
       call multifab_build(s2(n), mla%la(n), nscal, ng_s)
    end do

    call scalar_advance(nlevs,mla,1,uold,s1,s2,thermal,umac,w0,w0_cart_vec,eta, &
                        utrans,normal,s0_1,s0_2, &
                        p0_1,p0_2,dx,dt,the_bc_tower%bc_tower_array)

    do n=1,nlevs
       call destroy(thermal(n))
    end do

    if(.not. do_half_alg) then
       do n=1,nlevs
          do comp=1,dm
             call destroy(umac(n,comp))
             call destroy(utrans(n,comp))
          end do
       end do
    end if

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 4a (Option I) -- Add thermal conduction (only enthalpy terms)
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    
    if (use_thermal_diffusion) then
       if (parallel_IOProcessor() .and. verbose .ge. 1) then
          write(6,*) '<<< STEP  4a: thermal conduct >>>'
       end if
       
       if(do_half_alg) then
          call thermal_conduct_half_alg(mla,dx,dt,s1,s2,p0_1,p0_2, &
                                        s0_1(:,:,temp_comp), s0_2(:,:,temp_comp), &
                                        the_bc_tower)
       else
          call thermal_conduct_full_alg(mla,dx,dt,s1,s1,s2,p0_1,p0_2, &
                                        s0_1(:,:,temp_comp),s0_2(:,:,temp_comp), &
                                        the_bc_tower)
          
          ! make a copy of s2star since these are needed to compute
          ! coefficients in the call to thermal_conduct_full_alg
          do n=1,nlevs
             call multifab_build(s2star(n), mla%la(n), nscal, ng_s)
             call multifab_copy_c(s2star(n), 1, s2(n), 1, nscal, ng_s)
          end do
       end if
    end if

    if(do_half_alg) then
       do n=1,nlevs
          call destroy(s1(n))
       end do
    end if
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 5 -- react the full state and then base state through dt/2
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    
    if (parallel_IOProcessor() .and. verbose .ge. 1) then
       write(6,*) '<<< STEP  5 : react state     '
       write(6,*) '            : react  base >>> '
    end if

    do n=1,nlevs
       call multifab_build(rho_Hext(n), mla%la(n), 1, 0)
    end do
    
    call react_state(nlevs,mla,s2,snew,rho_omegadot2,rho_Hext,halfdt,dx, &
                     the_bc_tower%bc_tower_array,time)

    do n=1,nlevs
       call destroy(s2(n))
    end do

    call average(mla,rho_omegadot2,rho_omegadotbar2,dx,1,nspec)
    call average(mla,rho_Hext,rho_Hextbar,dx,1,1)
    if (evolve_base_state) then
       call react_base(nlevs,p0_2,s0_2,rho_omegadotbar2,rho_Hextbar(:,:,1),halfdt, &
                       p0_new,s0_new,gam1)
    else
       p0_new = p0_2
       s0_new = s0_2
    end if

    do n=1,nlevs
       call make_grav_cell(n,grav_cell_new(n,:),s0_new(n,:,rho_comp))
       call make_div_coeff(n,div_coeff_new(n,:),s0_new(n,:,rho_comp),p0_new(n,:), &
                           gam1(n,:),grav_cell_new(n,:))
    end do
    
    ! Define base state at half time for use in velocity advance!
    do n=1,nlevs
       do j=0,nr(n)-1
          s0_nph(n,j,:) = HALF * (s0_old(n,j,:) + s0_new(n,j,:))
       end do

       call make_grav_cell(n,grav_cell_nph(n,:),s0_nph(n,:,rho_comp))

       do j=0,nr(n)-1
          div_coeff_nph(n,j) = HALF * (div_coeff_old(n,j) + div_coeff_new(n,j))
       end do
    end do
    
    if(.not. do_half_alg) then
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 6 -- define a new average expansion rate at n+1/2
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
       
       if (parallel_IOProcessor() .and. verbose .ge. 1) then
          write(6,*) '<<< STEP  6 : make new S and new w0 >>> '
       end if
       
       do n=1,nlevs
          call multifab_build(thermal(n), mla%la(n), 1, 1)
       end do

       if(use_thermal_diffusion) then
          call make_explicit_thermal(mla,dx,thermal,snew,p0_new, &
                                     the_bc_tower,temp_diffusion_formulation)
       else
          do n=1,nlevs
             call setval(thermal(n),ZERO,all=.true.)
          end do
       end if
       
       do n=1,nlevs
          call multifab_build(gamma1_term(n), mla%la(n), 1, 0)
       end do

       call make_S(nlevs,Source_new,gamma1_term,snew,rho_omegadot2,rho_Hext,thermal, &
                   s0_old(:,:,temp_comp),gam1,dx)
       
       do n=1,nlevs
          call destroy(rho_Hext(n))
          call destroy(thermal(n))
       end do

       do n=1,nlevs
          call multifab_build(Source_nph(n), mla%la(n), 1, 0)
       end do

       call make_S_at_halftime(nlevs,Source_nph,Source_old,Source_new)
       
       do n=1,nlevs
          call average(mla,Source_nph,Sbar,dx,1,1)
       end do
       
       call make_w0(nlevs,w0,w0_old,w0_force,Sbar(:,:,1),p0_new, &
                    s0_new(:,:,rho_comp),gam1,eta,dt,dtold)
       
       if (dm .eq. 3) then

          do n=1,nlevs
             call multifab_build(w0_force_cart_vec(n), mla%la(n), dm, 1)
          end do

          call make_w0_cart(nlevs,w0      ,w0_cart_vec      ,normal,dx) 
          call make_w0_cart(nlevs,w0_force,w0_force_cart_vec,normal,dx) 
       end if
       
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 7 -- redo the construction of the advective velocity using the current w0
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
       if (parallel_IOProcessor() .and. verbose .ge. 1) then
          write(6,*) '<<< STEP  7 : create MAC velocities >>> '
       end if

       do n=1,nlevs
          do comp=1,dm
             umac_nodal_flag = .false.
             umac_nodal_flag(comp) = .true.
             call multifab_build(  umac(n,comp), mla%la(n),  1, 1, nodal = umac_nodal_flag)
             call multifab_build(utrans(n,comp), mla%la(n),  1, 1, nodal = umac_nodal_flag)
          end do
       end do

       call advance_premac(nlevs,uold,sold,umac,utrans,gpres,normal,w0, &
                           w0_cart_vec,s0_old,grav_cell_old,dx,dt, &
                           the_bc_tower%bc_tower_array,mla)

       do n=1,nlevs
          call multifab_build(macrhs(n), mla%la(n), 1, 0)
       end do

       call make_macrhs(nlevs,macrhs,Source_nph,gamma1_term,Sbar(:,:,1),div_coeff_nph,dx)
    
       do n=1,nlevs
          call destroy(gamma1_term(n))
          call destroy(Source_nph(n))
       end do

       do n=1,nlevs
          call multifab_build(rhohalf(n), mla%la(n), 1, 1)
       end do

       call make_at_halftime(nlevs,rhohalf,sold,snew,rho_comp,1,dx, &
                             the_bc_tower%bc_tower_array,mla)
       
       ! MAC projection !
       if (spherical .eq. 1) then
          do n=1,nlevs
             call multifab_build(div_coeff_3d(n), mla%la(nlevs), 1, 1)
          end do

          call fill_3d_data_wrapper(nlevs,div_coeff_3d,div_coeff_nph,dx)
          call macproject(mla,umac,macphi,rhohalf,dx,the_bc_tower, &
                          press_comp,macrhs,div_coeff_3d=div_coeff_3d)

          do n=1,nlevs
             call destroy(div_coeff_3d(n))
          end do
       else
          do n=1,nlevs
             call cell_to_edge(n,div_coeff_nph(n,:),div_coeff_edge(n,:))
          end do
          call macproject(mla,umac,macphi,rhohalf,dx,the_bc_tower, &
                          press_comp,macrhs,div_coeff_1d=div_coeff_nph, &
                          div_coeff_half_1d=div_coeff_edge)
       end if

       do n=1,nlevs
          call destroy(rhohalf(n))
          call destroy(macrhs(n))
          call destroy(macphi(n))
       end do
        
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 8 -- advect the base state and full state through dt
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
       
       if (parallel_IOProcessor() .and. verbose .ge. 1) then
          write(6,*) '<<< STEP  8 : advect base   '
          write(6,*) '            : scalar_advance >>>'
       end if
       if (evolve_base_state) then
          call advect_base(nlevs,w0,Sbar,p0_1,p0_2,s0_1,s0_2,gam1,div_coeff_nph,eta, &
                           dx(:,dm),dt)
       else
          p0_2 = p0_1
          s0_2 = s0_1
       end if
              
       do n=1,nlevs
          call multifab_build(thermal(n), mla%la(n), 1, 1)
       end do

       if(use_thermal_diffusion) then
          call make_explicit_thermal(mla,dx,thermal,s1,p0_1, &
                                     the_bc_tower,temp_diffusion_formulation)
       else
          do n=1,nlevs
             call setval(thermal(n),ZERO,all=.true.)
          end do
       end if
       
       ! thermal is the temperature forcing if we use the temperature godunov predictor
       ! so we add the reaction terms to thermal
       if(istep .le. 1) then
          call add_react_to_thermal(nlevs,thermal,rho_omegadot1,s1, &
                                    the_bc_tower%bc_tower_array,mla,dx)
       else
          call add_react_to_thermal(nlevs,thermal,rho_omegadot2_hold,s1, &
                                    the_bc_tower%bc_tower_array,mla,dx)

          do n=1,nlevs
             call destroy(rho_omegadot2_hold(n))
          end do
       end if

       do n=1,nlevs
          call destroy(rho_omegadot1(n))
       end do
       
       do n=1,nlevs
          call multifab_build(s2(n), mla%la(n), nscal, ng_s)
       end do

       call scalar_advance(nlevs,mla,2,uold,s1,s2,thermal,umac,w0,w0_cart_vec,eta, &
                           utrans,normal,s0_1,s0_2, &
                           p0_1,p0_2,dx,dt,the_bc_tower%bc_tower_array)

       do n=1,nlevs
          call destroy(thermal(n))
       end do
       
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 8a (Option I) -- Add thermal conduction (only enthalpy terms)
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
       
       if (use_thermal_diffusion) then
          if (parallel_IOProcessor() .and. verbose .ge. 1) then
             write(6,*) '<<< STEP  8a: thermal conduct >>>'
          end if
          
          call thermal_conduct_full_alg(mla,dx,dt,s1,s2star,s2,p0_1,p0_2, &
                                        s0_1(:,:,temp_comp),s0_2(:,:,temp_comp), &
                                        the_bc_tower)

          do n=1,nlevs
             call destroy(s2star(n))
          end do
       end if

       do n=1,nlevs
          call destroy(s1(n))
       end do

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 9 -- react the full state and then base state through dt/2
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
       
       if (parallel_IOProcessor() .and. verbose .ge. 1) then
          write(6,*) '<<< STEP  9 : react state '
          write(6,*) '            : react  base >>>'
       end if

       do n=1,nlevs
          call multifab_build(rho_Hext(n), mla%la(n), 1, 0)
       end do
       
       call react_state(nlevs,mla,s2,snew,rho_omegadot2,rho_Hext,halfdt,dx,&
                        the_bc_tower%bc_tower_array,time)

       do n=1,nlevs
          call destroy(s2(n))
       end do

       call average(mla,rho_omegadot2,rho_omegadotbar2,dx,1,nspec)
       call average(mla,rho_Hext,rho_Hextbar,dx,1,1)
       if (evolve_base_state) then
          call react_base(nlevs,p0_2,s0_2,rho_omegadotbar2,rho_Hextbar(:,:,1),halfdt, &
                          p0_new,s0_new,gam1)
       else
          p0_new = p0_2
          s0_new = s0_2
       end if

       do n=1,nlevs
          call make_grav_cell(n,grav_cell_new(n,:),s0_new(n,:,rho_comp))
          call make_div_coeff(n,div_coeff_new(n,:),s0_new(n,:,rho_comp),p0_new(n,:), &
                              gam1(n,:),grav_cell_new(n,:))
       end do
       
       ! end if corresponding to .not. do_half_alg
    end if

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 10 -- compute S^{n+1} for the final projection
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    
    if (parallel_IOProcessor() .and. verbose .ge. 1) then
       write(6,*) '<<< STEP 10 : make new S >>>'
    end if
          
    do n=1,nlevs
       call multifab_build(thermal(n), mla%la(n), 1, 1)
    end do

    if(use_thermal_diffusion) then
       call make_explicit_thermal(mla,dx,thermal,snew,p0_new, &
                                  the_bc_tower,temp_diffusion_formulation)
    else
       do n=1,nlevs
          call setval(thermal(n),ZERO,all=.true.)
       end do
    end if
    
    do n=1,nlevs
       call multifab_build(gamma1_term(n), mla%la(n), 1, 0)
    end do

    call make_S(nlevs,Source_new,gamma1_term,snew,rho_omegadot2,rho_Hext,thermal, &
                s0_new(:,:,temp_comp),gam1,dx)

    do n=1,nlevs
       call destroy(rho_Hext(n))
       call destroy(thermal(n))
    end do

    call average(mla,Source_new,Sbar,dx,1,1)
    
    ! define dSdt = (Source_new - Source_old) / dt
    do n=1,nlevs
       call multifab_copy(dSdt(n),Source_new(n))
       call multifab_sub_sub(dSdt(n),Source_old(n))
       call multifab_div_div_s(dSdt(n),dt)
    end do
    
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! STEP 11 -- update the velocity
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    
    if (parallel_IOProcessor() .and. verbose .ge. 1) then
       write(6,*) '<<< STEP 11 : update and project new velocity >>>'
    end if
    
    ! Define rho at half time using the new rho from Step 8!
    do n=1,nlevs
       call multifab_build(rhohalf(n), mla%la(n), 1, 1)
    end do

    call make_at_halftime(nlevs,rhohalf,sold,snew,rho_comp,1,dx, &
                          the_bc_tower%bc_tower_array,mla)
    
    call velocity_advance(nlevs,mla,uold,unew,sold,rhohalf,umac,utrans,gpres, &
                          normal,w0,w0_cart_vec,w0_force,w0_force_cart_vec,s0_old,s0_nph, &
                          grav_cell_old,grav_cell_nph,dx,dt, &
                          the_bc_tower%bc_tower_array,sponge)

    do n=1,nlevs
       do comp=1,dm
          call destroy(umac(n,comp))
          call destroy(utrans(n,comp))
       end do
    end do

    if (dm .eq. 3) then
       do n=1,nlevs
          call destroy(w0_cart_vec(n))
          call destroy(w0_force_cart_vec(n))
       end do
    end if

    ! Define beta at half time using the div_coeff_new from step 9!
    do n=1,nlevs
       do j=0,nr(n)-1
          div_coeff_nph(n,j) = HALF * (div_coeff_old(n,j) + div_coeff_new(n,j))
       end do
    end do
       
    ! Project the new velocity field.
    if (init_mode) then
       proj_type = pressure_iters_comp

       do n=1,nlevs
          call multifab_build(hgrhs_old(n), mla%la(n), 1, 0, nodal)
          call multifab_copy(hgrhs_old(n),hgrhs(n))
       end do
       call make_hgrhs(nlevs,hgrhs,Source_new,gamma1_term,Sbar(:,:,1),div_coeff_new,dx)
       do n=1,nlevs
          call multifab_sub_sub(hgrhs(n),hgrhs_old(n))
          call multifab_div_div_s(hgrhs(n),dt)
       end do
    else
       proj_type = regular_timestep_comp
       call make_hgrhs(nlevs,hgrhs,Source_new,gamma1_term,Sbar(:,:,1),div_coeff_new,dx)
    end if

    do n=1,nlevs
       call destroy(gamma1_term(n))
    end do

    if (spherical .eq. 1) then
       do n=1,nlevs
          call multifab_build(div_coeff_3d(n), mla%la(nlevs), 1, 1)
       end do
       
       call fill_3d_data_wrapper(nlevs,div_coeff_3d,div_coeff_nph,dx)
       eps_in = 1.d-12
       call hgproject(proj_type, mla, unew, uold, rhohalf, pres, gpres, dx, dt, &
                      the_bc_tower, press_comp, &
                      hgrhs, div_coeff_3d=div_coeff_3d, eps_in = eps_in)

       do n=1,nlevs
          call destroy(div_coeff_3d(n))
       end do
    else
       call hgproject(proj_type, mla, unew, uold, rhohalf, pres, gpres, dx, dt, &
                      the_bc_tower, press_comp, &
                      hgrhs, div_coeff_1d=div_coeff_nph)
    end if

    do n=1,nlevs
       call destroy(rhohalf(n))
    end do
    
    ! If doing pressure iterations then put hgrhs_old into hgrhs to be returned to varden.
    if (init_mode) then
       do n=1,nlevs
          call multifab_copy(hgrhs(n),hgrhs_old(n))
          call destroy(hgrhs_old(n))
       end do
    end if

    deallocate(rhohalf,w0_cart_vec,w0_force_cart_vec,macrhs,macphi,hgrhs_old,Source_nph)
    deallocate(thermal,s2star,rho_omegadot2_hold,s1,s2,gamma1_term,rho_omegadot1)
    deallocate(rho_Hext,div_coeff_3d)
    deallocate(umac,utrans)
    deallocate(umac_nodal_flag)
    deallocate(grav_cell_nph,grav_cell_new,s0_nph,w0_force,w0_old,Sbar)
    deallocate(div_coeff_nph,div_coeff_edge,rho_omegadotbar1,rho_omegadotbar2,rho_Hextbar)
    deallocate(eta,s0_1,s0_2,p0_1,p0_2)
    deallocate(lo,hi)

    call destroy(bpt)
    
  end subroutine advance_timestep

end module advance_timestep_module
