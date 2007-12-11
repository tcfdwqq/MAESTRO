module mkscalforce_module

  ! this module contains the 2d and 3d routines that make the 
  ! forcing term, w dp/dr,  for rho*h .  

  use bl_constants_module
  use fill_3d_module
  use variables
  use geometry
  use eos_module
  use multifab_module
  use ml_layout_module
  use define_bc_module
  use ml_restriction_module
  use multifab_fill_ghost_module

  implicit none

  private
  public :: mkrhohforce
  public :: mktempforce
contains

  subroutine mkrhohforce(n,scal_force,comp,umac,p0_old,p0_new,normal,dx)

    integer        , intent(in   ) :: n
    type(multifab) , intent(inout) :: scal_force
    integer        , intent(in   ) :: comp
    type(multifab) , intent(in   ) :: umac(:)
    real(kind=dp_t), intent(in   ) :: p0_old(0:)
    real(kind=dp_t), intent(in   ) :: p0_new(0:)
    type(multifab) , intent(in   ) :: normal
    real(kind=dp_t), intent(in   ) :: dx(:)

    ! local
    integer                  :: i,dm
    integer                  :: lo(scal_force%dim),hi(scal_force%dim)    
    real(kind=dp_t), pointer :: ump(:,:,:,:)
    real(kind=dp_t), pointer :: vmp(:,:,:,:)
    real(kind=dp_t), pointer :: wmp(:,:,:,:)
    real(kind=dp_t), pointer :: np(:,:,:,:)
    real(kind=dp_t), pointer :: fp(:,:,:,:)

    dm = scal_force%dim
      
    do i=1,scal_force%nboxes
       if ( multifab_remote(scal_force,i) ) cycle
       fp => dataptr(scal_force, i)
       ump => dataptr(umac(1),i)
       vmp => dataptr(umac(2),i)
       lo = lwb(get_box(scal_force,i))
       hi = upb(get_box(scal_force,i))
       select case (dm)
       case (2)
          call mkrhohforce_2d(n,fp(:,:,1,comp), vmp(:,:,1,1), lo, hi, p0_old, p0_new)
       case(3)
          wmp  => dataptr(umac(3), i)
          if (spherical .eq. 0) then
             call mkrhohforce_3d(n,fp(:,:,:,comp), wmp(:,:,:,1), lo, hi, p0_old, p0_new)
          else
             np => dataptr(normal, i)
             call mkrhohforce_3d_sphr(n,fp(:,:,:,comp), &
                                      ump(:,:,:,1), vmp(:,:,:,1), wmp(:,:,:,1), &
                                      lo, hi, dx, np(:,:,:,:), p0_old, p0_new)
          end if
       end select
    end do
    
  end subroutine mkrhohforce

  subroutine mkrhohforce_2d(n,rhoh_force,wmac,lo,hi,p0_old,p0_new)

    ! compute the source terms for the non-reactive part of the enthalpy equation {w dp0/dr}
    
    ! note, in the prediction of the interface states, we will set
    ! both p0_old and p0_new to the same old value.  In the computation
    ! of the rhoh_force for the update, they will be used to time-center.

    integer,         intent(in   ) :: n,lo(:),hi(:)
    real(kind=dp_t), intent(  out) :: rhoh_force(lo(1)-1:,lo(2)-1:)
    real(kind=dp_t), intent(in   ) :: wmac(lo(1)-1:,lo(2)-1:)
    real(kind=dp_t), intent(in   ) :: p0_old(0:)
    real(kind=dp_t), intent(in   ) :: p0_new(0:)

    real(kind=dp_t) :: gradp0, wadv
    integer :: i,j

    rhoh_force = ZERO

!   Add w d(p0)/dz 
    do j = lo(2),hi(2)
       if (j.eq.0) then
          gradp0 = HALF * ( p0_old(j+1) + p0_new(j+1) &
                           -p0_old(j  ) - p0_new(j  ) ) / dr(n)
       else if (j.eq.nr(n)-1) then
          gradp0 = HALF * ( p0_old(j  ) + p0_new(j  ) &
                           -p0_old(j-1) - p0_new(j-1) ) / dr(n)
       else
          gradp0 = FOURTH * ( p0_old(j+1) + p0_new(j+1) &
                             -p0_old(j-1) - p0_new(j-1) ) / dr(n)
       end if
       do i = lo(1),hi(1)
          wadv = HALF*(wmac(i,j)+wmac(i,j+1))
          rhoh_force(i,j) =  wadv * gradp0 
       end do
    end do

  end subroutine mkrhohforce_2d

  subroutine mkrhohforce_3d(n,rhoh_force,wmac,lo,hi,p0_old,p0_new)

    ! compute the source terms for the non-reactive part of the enthalpy equation {w dp0/dr}

    integer,         intent(in   ) :: n,lo(:),hi(:)
    real(kind=dp_t), intent(  out) :: rhoh_force(lo(1)-1:,lo(2)-1:,lo(3)-1:)
    real(kind=dp_t), intent(in   ) :: wmac(lo(1)-1:,lo(2)-1:,lo(3)-1:)
    real(kind=dp_t), intent(in   ) :: p0_old(0:)
    real(kind=dp_t), intent(in   ) :: p0_new(0:)

    real(kind=dp_t) :: gradp0,wadv
    integer :: i,j,k

    rhoh_force = ZERO
 
    do k = lo(3),hi(3)

       if (k.eq.0) then
          gradp0 = HALF * ( p0_old(k+1) + p0_new(k+1) &
                           -p0_old(k  ) - p0_new(k  ) ) / dr(n)
       else if (k.eq.nr(n)-1) then
          gradp0 = HALF * ( p0_old(k  ) + p0_new(k  ) &
                           -p0_old(k-1) - p0_new(k-1) ) / dr(n)
       else
          gradp0 = FOURTH * ( p0_old(k+1) + p0_new(k+1) &
                             -p0_old(k-1) - p0_new(k-1) ) / dr(n)
       end if

       do j = lo(2),hi(2)
          do i = lo(1),hi(1)
             wadv = HALF*(wmac(i,j,k)+wmac(i,j,k+1))
             rhoh_force(i,j,k) = wadv * gradp0 
          end do
       end do

    end do

  end subroutine mkrhohforce_3d

  subroutine mkrhohforce_3d_sphr(n,rhoh_force,umac,vmac,wmac,lo,hi,dx,normal,p0_old,p0_new)

    ! compute the source terms for the non-reactive part of the enthalpy equation {w dp0/dr}

    integer,         intent(in   ) :: n,lo(:),hi(:)
    real(kind=dp_t), intent(  out) :: rhoh_force(lo(1)-1:,lo(2)-1:,lo(3)-1:)
    real(kind=dp_t), intent(in   ) :: umac(lo(1)-1:,lo(2)-1:,lo(3)-1:)
    real(kind=dp_t), intent(in   ) :: vmac(lo(1)-1:,lo(2)-1:,lo(3)-1:)
    real(kind=dp_t), intent(in   ) :: wmac(lo(1)-1:,lo(2)-1:,lo(3)-1:)
    real(kind=dp_t), intent(in   ) :: normal(lo(1)-1:,lo(2)-1:,lo(3)-1:,:)
    real(kind=dp_t), intent(in   ) :: dx(:)
    real(kind=dp_t), intent(in   ) :: p0_old(0:)
    real(kind=dp_t), intent(in   ) :: p0_new(0:)

    real(kind=dp_t) :: uadv,vadv,wadv,normal_vel
    real(kind=dp_t), allocatable :: gradp_rad(:)
    real(kind=dp_t), allocatable :: gradp_cart(:,:,:)
    integer :: i,j,k

    allocate(gradp_rad(0:nr(n)-1))
    allocate(gradp_cart(lo(1):hi(1),lo(2):hi(2),lo(3):hi(3)))
 
    rhoh_force = ZERO

    do k = 0, nr(n)-1
       
       if (k.eq.0) then
          gradp_rad(k) = HALF * ( p0_old(k+1) + p0_new(k+1) &
                                 -p0_old(k  ) - p0_new(k  ) ) / dr(n)
       else if (k.eq.nr(n)-1) then 
          gradp_rad(k) = HALF * ( p0_old(k  ) + p0_new(k  ) &
                                 -p0_old(k-1) - p0_new(k-1) ) / dr(n)
       else
          gradp_rad(k) = FOURTH * ( p0_old(k+1) + p0_new(k+1) &
                                   -p0_old(k-1) - p0_new(k-1) ) / dr(n)
       end if
    end do

    call fill_3d_data(n,gradp_cart,gradp_rad,lo,hi,dx,0)

    do k = lo(3),hi(3)
       do j = lo(2),hi(2)
          do i = lo(1),hi(1)

             uadv = HALF*(umac(i,j,k)+umac(i+1,j,k))
             vadv = HALF*(vmac(i,j,k)+vmac(i,j+1,k))
             wadv = HALF*(wmac(i,j,k)+wmac(i,j,k+1))

             normal_vel = uadv*normal(i,j,k,1)+vadv*normal(i,j,k,2)+wadv*normal(i,j,k,3)

             rhoh_force(i,j,k) = gradp_cart(i,j,k) * normal_vel

          end do
       end do
    end do

    deallocate(gradp_rad, gradp_cart)

  end subroutine mkrhohforce_3d_sphr

  subroutine mktempforce(nlevs,temp_force,comp,s,thermal,p0_old,dx,mla,the_bc_level)

    integer        , intent(in   ) :: nlevs
    type(multifab) , intent(inout) :: temp_force(:)
    integer        , intent(in   ) :: comp
    type(multifab) , intent(in   ) :: s(:)
    type(multifab) , intent(in   ) :: thermal(:)
    real(kind=dp_t), intent(in   ) :: p0_old(:,0:)
    real(kind=dp_t), intent(in   ) :: dx(:,:)
    type(ml_layout), intent(inout) :: mla
    type(bc_level) , intent(in   ) :: the_bc_level(:)

    ! local
    integer                  :: i,dm,ng,n
    integer                  :: lo(temp_force(1)%dim),hi(temp_force(1)%dim)
    real(kind=dp_t), pointer :: tp(:,:,:,:)
    real(kind=dp_t), pointer :: sp(:,:,:,:)
    real(kind=dp_t), pointer :: fp(:,:,:,:)

    dm = temp_force(1)%dim
    ng = s(1)%ng

    do n=1,nlevs

       do i=1,temp_force(n)%nboxes
          if ( multifab_remote(temp_force(n),i) ) cycle
          fp => dataptr(temp_force(n),i)
          sp => dataptr(s(n),i)
          lo = lwb(get_box(s(n),i))
          hi = upb(get_box(s(n),i))
          tp => dataptr(thermal(n),i)
          select case (dm)
          case (2)
             call mktempforce_2d(fp(:,:,1,comp), sp(:,:,1,:), tp(:,:,1,1), lo, hi, &
                                 ng, p0_old(n,:))
          case(3)
             if (spherical .eq. 1) then
                call mktempforce_3d_sphr(n,fp(:,:,:,comp), sp(:,:,:,:), tp(:,:,:,1), &
                                         lo, hi, ng, p0_old(n,:), dx(n,:))
             else
                call mktempforce_3d(fp(:,:,:,comp), sp(:,:,:,:), tp(:,:,:,1), lo, hi, &
                                    ng, p0_old(n,:))
             end if
          end select
       end do
    
       call multifab_fill_boundary_c(temp_force(n),comp,1)
       call multifab_physbc(temp_force(n),comp,foextrap_comp,1,dx(n,:),the_bc_level(n))

    end do

    do n=nlevs,2,-1
       call ml_cc_restriction_c(temp_force(n-1),comp,temp_force(n),comp,mla%mba%rr(n-1,:),1)
       call multifab_fill_ghost_cells(temp_force(n),temp_force(n-1), &
                                      temp_force(n)%ng,mla%mba%rr(n-1,:), &
                                      the_bc_level(n-1),the_bc_level(n), &
                                      comp,foextrap_comp,1)
    enddo

  end subroutine mktempforce

  subroutine mktempforce_2d(temp_force, s, thermal, lo, hi, ng, p0)

    ! compute the source terms for temperature

    ! note, in the prediction of the interface states, we will set
    ! both p0_old and p0_new to the same old value.  In the computation
    ! of the temp_force for the update, they will be used to time-center.

    integer,         intent(in   ) :: lo(:),hi(:),ng
    real(kind=dp_t), intent(  out) :: temp_force(lo(1)-1:,lo(2)-1:)
    real(kind=dp_t), intent(in   ) :: s(lo(1)-ng:,lo(2)-ng:,:)
    real(kind=dp_t), intent(in   ) :: thermal(lo(1)-1:,lo(2)-1:)
    real(kind=dp_t), intent(in   ) :: p0(0:)

    integer :: i,j

    temp_force = ZERO

!   HACK HACK HACK 
!   We ignore the w d(p0) / dz term since p0 is essentially constant

    do j = lo(2),hi(2)
       do i = lo(1),hi(1)

          temp_eos(1) = s(i,j,temp_comp)
          den_eos(1) = s(i,j,rho_comp)
          xn_eos(1,:) = s(i,j,spec_comp:spec_comp+nspec-1)/den_eos(1)

          ! dens, temp, xmass inputs
         call eos(eos_input_rt, den_eos, temp_eos, &
                  npts, nspec, &
                  xn_eos, &
                  p_eos, h_eos, e_eos, &
                  cv_eos, cp_eos, xne_eos, eta_eos, pele_eos, &
                  dpdt_eos, dpdr_eos, dedt_eos, dedr_eos, &
                  dpdX_eos, dhdX_eos, &
                  gam1_eos, cs_eos, s_eos, &
                  dsdt_eos, dsdr_eos, &
                  do_diag)

          temp_force(i,j) =  thermal(i,j) / (s(i,j,rho_comp) * cp_eos(1))

       end do
    end do

  end subroutine mktempforce_2d

  subroutine mktempforce_3d(temp_force, s, thermal, lo, hi, ng, p0)

    ! compute the source terms for temperature

    ! note, in the prediction of the interface states, we will set
    ! both p0_old and p0_new to the same old value.  In the computation
    ! of the temp_force for the update, they will be used to time-center.

    integer,         intent(in   ) :: lo(:),hi(:),ng
    real(kind=dp_t), intent(  out) :: temp_force(lo(1)-1:,lo(2)-1:,lo(3)-1:)
    real(kind=dp_t), intent(in   ) :: s(lo(1)-ng:,lo(2)-ng:,lo(3)-ng:,:)
    real(kind=dp_t), intent(in   ) :: thermal(lo(1)-1:,lo(2)-1:,lo(3)-1:)
    real(kind=dp_t), intent(in   ) :: p0(0:)

    integer :: i,j,k

    temp_force = ZERO

!   HACK HACK HACK 
!   We ignore the w d(p0) / dz term since p0 is essentially constant

    do k = lo(3),hi(3)
     do j = lo(2),hi(2)
       do i = lo(1),hi(1)

          temp_eos(1) = s(i,j,k,temp_comp)
          den_eos(1) = s(i,j,k,rho_comp)
          xn_eos(1,:) = s(i,j,k,spec_comp:spec_comp+nspec-1)/den_eos(1)
          
          ! dens, temp, xmass inputs
         call eos(eos_input_rt, den_eos, temp_eos, &
                  npts, nspec, &
                  xn_eos, &
                  p_eos, h_eos, e_eos, &
                  cv_eos, cp_eos, xne_eos, eta_eos, pele_eos, &
                  dpdt_eos, dpdr_eos, dedt_eos, dedr_eos, &
                  dpdX_eos, dhdX_eos, &
                  gam1_eos, cs_eos, s_eos, &
                  dsdt_eos, dsdr_eos, &
                  do_diag)

          temp_force(i,j,k) =  thermal(i,j,k) / (s(i,j,k,rho_comp) * cp_eos(1))

       end do
     end do
    end do

  end subroutine mktempforce_3d

  subroutine mktempforce_3d_sphr(n,temp_force, s, thermal, lo, hi, ng, p0, dx)

    ! compute the source terms for temperature

    ! note, in the prediction of the interface states, we will set
    ! both p0_old and p0_new to the same old value.  In the computation
    ! of the temp_force for the update, they will be used to time-center.

    integer,         intent(in   ) :: n,lo(:),hi(:),ng
    real(kind=dp_t), intent(  out) :: temp_force(lo(1)-1:,lo(2)-1:,lo(3)-1:)
    real(kind=dp_t), intent(in   ) :: s(lo(1)-ng:,lo(2)-ng:,lo(3)-ng:,:)
    real(kind=dp_t), intent(in   ) :: thermal(lo(1)-1:,lo(2)-1:,lo(3)-1:)
    real(kind=dp_t), intent(in   ) :: p0(0:)
    real(kind=dp_t), intent(in   ) :: dx(:)
    real(kind=dp_t), allocatable   :: p0_cart(:,:,:)

    integer :: i,j,k

    allocate(p0_cart(lo(1):hi(1),lo(2):hi(2),lo(3):hi(3)))
    call fill_3d_data(n,p0_cart,p0,lo,hi,dx,0)

    temp_force = ZERO

!   HACK HACK HACK 
!   We ignore the w d(p0) / dz term since p0 is essentially constant

    do k = lo(3),hi(3)
     do j = lo(2),hi(2)
       do i = lo(1),hi(1)

          temp_eos(1) = s(i,j,k,temp_comp)
          den_eos(1) = s(i,j,k,rho_comp)
          xn_eos(1,:) = s(i,j,k,spec_comp:spec_comp+nspec-1)/den_eos(1)
          
          ! dens, temp, xmass inputs
         call eos(eos_input_rt, den_eos, temp_eos, &
                  npts, nspec, &
                  xn_eos, &
                  p_eos, h_eos, e_eos, &
                  cv_eos, cp_eos, xne_eos, eta_eos, pele_eos, &
                  dpdt_eos, dpdr_eos, dedt_eos, dedr_eos, &
                  dpdX_eos, dhdX_eos, &
                  gam1_eos, cs_eos, s_eos, &
                  dsdt_eos, dsdr_eos, &
                  do_diag)

          temp_force(i,j,k) =  thermal(i,j,k) / (s(i,j,k,rho_comp) * cp_eos(1))

       end do
     end do
    end do

    deallocate(p0_cart)

  end subroutine mktempforce_3d_sphr

end module mkscalforce_module
